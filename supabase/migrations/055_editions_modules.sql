-- 55: Editions (Basic / Professional), paid add-on modules, SNA staff console,
--     plan requests (upgrade, module, new outlet) and Basic limits.

-- ---------- catalogue ----------
alter table public.restaurants
  add column if not exists edition text not null default 'basic'
  check (edition in ('basic', 'professional'));
-- Restaurants that exist today keep every feature they already use.
update public.restaurants set edition = 'professional';

create table public.modules (
  key text primary key,
  name text not null,
  description text not null,
  kind text not null check (kind in ('professional', 'addon')),
  display_order smallint not null default 0
);
insert into public.modules (key, name, description, kind, display_order) values
  ('multi_outlet',     'Several outlets',            'More outlets with one central menu and prices per outlet', 'professional', 1),
  ('kitchen_stations', 'Kitchen stations',           'One KOT per station (kitchen, bar, dessert)',             'professional', 2),
  ('custom_roles',     'Custom security profiles',   'Create roles and tick what each can do',                   'professional', 3),
  ('stock',            'Stock and recipes',          'Ingredients, recipes, purchases, wastage, food cost',      'professional', 4),
  ('accounting',       'Accounting export',          'Journal for Tally, Zoho Books, Xero',                      'professional', 5),
  ('courses',          'Hold and fire',              'Hold items and send them to the kitchen later',            'professional', 6),
  ('merge',            'Merge bills',                'Join two tables into one bill',                            'professional', 7),
  ('reservations',     'Reservations and waitlist',  'Book tables and manage the queue',                         'professional', 8),
  ('timesheets',       'Staff timesheets',           'Clock in and out, hours per person',                       'professional', 9),
  ('central_kitchen',  'Central kitchen',            'Send stock from a central kitchen to outlets',             'professional', 10),
  ('open_api',         'Open API',                   'Connect other software with API keys',                     'professional', 11),
  ('whatsapp',         'WhatsApp',                   'Send bills and the day-end summary on WhatsApp',           'addon', 20),
  ('qr_ordering',      'QR table ordering',          'Guests scan the table QR and order from their phone',      'addon', 21),
  ('loyalty',          'Loyalty and gift cards',     'Points on every bill, gift cards as payment',              'addon', 22),
  ('owner_app',        'Owner mobile app',           'Sales, alerts and approvals on the owner''s phone',        'addon', 23),
  ('customer_display', 'Customer display',           'Second screen showing the order and total to the guest',   'addon', 24);

-- Monthly price per item ('basic', 'professional' or an add-on key) and currency.
create table public.plan_prices (
  item text not null,
  currency_code char(3) not null,
  monthly_price numeric(12,2),
  primary key (item, currency_code)
);
insert into public.plan_prices (item, currency_code, monthly_price) values
  ('basic', 'INR', 599), ('professional', 'INR', 1499),
  ('basic', 'AED', 99),  ('professional', 'AED', 249),
  ('basic', 'SGD', 39),  ('professional', 'SGD', 99),
  ('basic', 'MYR', 69),  ('professional', 'MYR', 159);

create table public.restaurant_modules (
  restaurant_id uuid not null references public.restaurants(id),
  module_key text not null references public.modules(key),
  enabled_at timestamptz not null default now(),
  enabled_by uuid,
  primary key (restaurant_id, module_key)
);

-- ---------- SNA staff ----------
create table public.sna_staff (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id),
  full_name text not null,
  email text not null,
  role text not null check (role in ('admin', 'sales', 'implementer', 'support')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.subscription_events (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid references public.restaurants(id),
  event text not null,
  details jsonb not null default '{}'::jsonb,
  staff_id uuid references public.sna_staff(id),
  user_id uuid references public.users(id),
  created_at timestamptz not null default now()
);
create trigger trg_no_update_subevents before update on public.subscription_events for each row execute function app.block_update();
create trigger trg_no_delete_subevents before delete on public.subscription_events for each row execute function app.block_delete();

create table public.plan_requests (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  kind text not null check (kind in ('upgrade', 'module', 'outlet')),
  module_key text references public.modules(key),
  outlet_name text,
  outlet_city text,
  note text,
  status text not null default 'requested' check (status in ('requested', 'approved', 'rejected', 'done', 'cancelled')),
  requested_by_user uuid references public.users(id),
  requested_by_staff uuid references public.sna_staff(id),
  decided_by uuid references public.sna_staff(id),
  decided_at timestamptz,
  decision_note text,
  done_by uuid references public.sna_staff(id),
  done_at timestamptz,
  branch_id uuid references public.branches(id),
  created_at timestamptz not null default now()
);
create index on public.plan_requests (status, created_at);

alter table public.modules enable row level security;
alter table public.plan_prices enable row level security;
alter table public.restaurant_modules enable row level security;
alter table public.sna_staff enable row level security;
alter table public.subscription_events enable row level security;
alter table public.plan_requests enable row level security;
revoke all on public.modules, public.plan_prices, public.restaurant_modules, public.sna_staff,
              public.subscription_events, public.plan_requests from anon, authenticated;
grant select on public.modules, public.plan_prices to authenticated;
grant select on public.restaurant_modules, public.plan_requests to authenticated;
create policy all_read on public.modules for select to authenticated using (true);
create policy all_read on public.plan_prices for select to authenticated using (true);
create policy tenant_read on public.restaurant_modules for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()));
create policy tenant_read on public.plan_requests for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id()));

-- Outlets are only added by an SNA implementer.
drop policy if exists perm_insert on public.branches;

-- ---------- helpers ----------
create or replace function app.sna_staff_id() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select s.id from public.sna_staff s where s.auth_user_id = auth.uid() and s.is_active
$$;

create or replace function app.sna_require(p_roles text[]) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.sna_staff%rowtype;
begin
  select * into s from public.sna_staff where auth_user_id = auth.uid() and is_active;
  if not found then raise exception 'Only SNA staff can do this.'; end if;
  if s.role <> 'admin' and not (s.role = any(p_roles)) then
    raise exception 'Your SNA role (%) cannot do this.', s.role;
  end if;
  return s.id;
end $$;

create or replace function app.feature_on(p_restaurant uuid, p_key text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select case m.kind
             when 'professional' then r.edition = 'professional'
             else exists (select 1 from public.restaurant_modules rm
                           where rm.restaurant_id = r.id and rm.module_key = m.key)
           end
      from public.modules m, public.restaurants r
     where m.key = p_key and r.id = p_restaurant), false)
$$;

create or replace function app.require_feature(p_key text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare m public.modules%rowtype;
begin
  if app.feature_on(app.current_restaurant_id(), p_key) then return; end if;
  select * into m from public.modules where key = p_key;
  if m.kind = 'professional' then
    raise exception '% needs the Professional edition. Ask for the upgrade in Settings → Plan and modules.', coalesce(m.name, p_key);
  end if;
  raise exception 'The % module is not switched on. Ask for it in Settings → Plan and modules.', coalesce(m.name, p_key);
end $$;

create or replace function app.log_plan(p_restaurant uuid, p_event text, p_details jsonb) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.subscription_events (restaurant_id, event, details, staff_id, user_id)
  values (p_restaurant, p_event, coalesce(p_details, '{}'::jsonb), app.sna_staff_id(), app.current_user_id())
$$;

-- ---------- Basic limits ----------
create or replace function app.basic_limits() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ed text; v_n int;
begin
  select edition into v_ed from public.restaurants where id = new.restaurant_id;
  if v_ed <> 'basic' then return new; end if;
  if tg_table_name = 'products' then
    if new.deleted_at is not null then return new; end if;
    if tg_op = 'UPDATE' and old.deleted_at is null then return new; end if;
    select count(*) into v_n from public.products where restaurant_id = new.restaurant_id and deleted_at is null and id <> new.id;
    if v_n >= 300 then raise exception 'The Basic edition allows up to 300 menu items. Upgrade to Professional for more.'; end if;
  elsif tg_table_name = 'users' then
    if not new.is_active or new.deleted_at is not null then return new; end if;
    if tg_op = 'UPDATE' and old.is_active and old.deleted_at is null then return new; end if;
    select count(*) into v_n from public.users where restaurant_id = new.restaurant_id and is_active and deleted_at is null and id <> new.id;
    if v_n >= 10 then raise exception 'The Basic edition allows up to 10 active staff. Upgrade to Professional for more.'; end if;
  elsif tg_table_name = 'devices' then
    if not new.is_active then return new; end if;
    if tg_op = 'UPDATE' and old.is_active then return new; end if;
    select count(*) into v_n from public.devices where restaurant_id = new.restaurant_id and is_active and id <> new.id;
    if v_n >= 2 then raise exception 'The Basic edition allows up to 2 counter tablets. Upgrade to Professional for more.'; end if;
  elsif tg_table_name = 'branches' then
    if new.deleted_at is not null then return new; end if;
    if tg_op = 'UPDATE' and old.deleted_at is null then return new; end if;
    select count(*) into v_n from public.branches where restaurant_id = new.restaurant_id and deleted_at is null and id <> new.id;
    if v_n >= 1 then raise exception 'The Basic edition has one outlet. Upgrade to Professional to add outlets.'; end if;
  end if;
  return new;
end $$;
create trigger trg_basic_limits before insert or update of deleted_at on public.products for each row execute function app.basic_limits();
create trigger trg_basic_limits before insert or update of is_active, deleted_at on public.users for each row execute function app.basic_limits();
create trigger trg_basic_limits before insert or update of is_active on public.devices for each row execute function app.basic_limits();
create trigger trg_basic_limits before insert or update of deleted_at on public.branches for each row execute function app.basic_limits();

-- ---------- gate Professional features inside existing functions ----------
do $$
declare r record; v_def text;
begin
  for r in select * from (values
      ('public.save_role(uuid,text,text[])', 'custom_roles'),
      ('public.delete_role(uuid)', 'custom_roles'),
      ('public.save_ingredient(uuid,text,text,numeric,numeric)', 'stock'),
      ('public.save_recipe(uuid,jsonb)', 'stock'),
      ('public.record_stock(uuid,text,numeric,numeric,text)', 'stock'),
      ('public.stock_report(date,date)', 'stock'),
      ('public.accounting_journal(date,date)', 'accounting'),
      ('public.merge_orders(uuid,uuid)', 'merge'),
      ('public.fire_held_items(uuid)', 'courses')) as t(fn, feat)
  loop
    v_def := pg_get_functiondef(r.fn::regprocedure);
    if position('app.require_feature' in v_def) > 0 then continue; end if;
    v_def := regexp_replace(v_def, E'\nbegin\n', E'\nbegin\n  perform app.require_feature(''' || r.feat || E''');\n');
    execute v_def;
  end loop;

  -- Basic: every item goes to one "Kitchen" ticket.
  v_def := pg_get_functiondef('app.create_kitchen_ticket(uuid,uuid[])'::regprocedure);
  v_def := replace(v_def, 'coalesce(nullif(trim(p.kitchen_station), ''''), ''Kitchen'')',
    'case when app.feature_on(o.restaurant_id, ''kitchen_stations'') then coalesce(nullif(trim(p.kitchen_station), ''''), ''Kitchen'') else ''Kitchen'' end');
  execute v_def;

  -- Basic: items cannot be held (hold / fire is Professional).
  v_def := pg_get_functiondef('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure);
  v_def := replace(v_def, '''held'', coalesce((v_item->>''hold'')::boolean, false)',
    '''held'', coalesce((v_item->>''hold'')::boolean, false) and app.feature_on(p_restaurant, ''courses'')');
  execute v_def;
end $$;

-- ---------- current user view: edition and features ----------
create or replace view public.v_current_user with (security_invoker = false) as
 select u.id as user_id, u.restaurant_id, u.full_name, u.email, u.employee_code,
        r.id as role_id, r.name as role_name, res.trading_name, res.country_code, res.currency_code, res.timezone,
        (select coalesce(array_agg(rp.permission_key order by rp.permission_key), '{}'::text[])
           from public.role_permissions rp where rp.role_id = r.id) as permissions,
        u.must_change_password,
        (select d.name from public.devices d where d.id = app.device_id()) as device_name,
        res.edition,
        (select coalesce(array_agg(m.key order by m.key), '{}'::text[])
           from public.modules m where app.feature_on(res.id, m.key)) as features,
        (app.sna_staff_id() is not null) as is_sna_staff
   from public.users u
   join public.roles r on r.id = u.role_id
   join public.restaurants res on res.id = u.restaurant_id
  where u.id = app.current_user_id();

-- ---------- restaurant side ----------
create or replace function public.my_plan() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_r public.restaurants%rowtype;
begin
  select * into v_r from public.restaurants where id = app.current_restaurant_id();
  if not found then raise exception 'You are not signed in to a restaurant.'; end if;
  return jsonb_build_object(
    'edition', v_r.edition,
    'currency', v_r.currency_code,
    'prices', (select coalesce(jsonb_object_agg(item, monthly_price), '{}'::jsonb)
                 from public.plan_prices where currency_code = v_r.currency_code),
    'modules', (select jsonb_agg(jsonb_build_object('key', m.key, 'name', m.name, 'description', m.description,
                                   'kind', m.kind, 'on', app.feature_on(v_r.id, m.key)) order by m.display_order)
                  from public.modules m),
    'outlets', (select count(*) from public.branches where restaurant_id = v_r.id and deleted_at is null),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'module_key', q.module_key,
                   'outlet_name', q.outlet_name, 'status', q.status, 'created_at', q.created_at,
                   'decision_note', q.decision_note) order by q.created_at desc), '[]'::jsonb)
                   from (select * from public.plan_requests where restaurant_id = v_r.id order by created_at desc limit 20) q));
end $$;

create or replace function public.request_plan_change(p_kind text, p_module text default null,
  p_outlet_name text default null, p_outlet_city text default null, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_id uuid; v_ed text;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if not app.is_owner() then raise exception 'Only the owner can ask for plan changes.'; end if;
  select edition into v_ed from public.restaurants where id = v_rest;
  if p_kind = 'upgrade' then
    if v_ed = 'professional' then raise exception 'You already have the Professional edition.'; end if;
  elsif p_kind = 'module' then
    if not exists (select 1 from public.modules where key = p_module and kind = 'addon') then
      raise exception 'Choose an add-on module.';
    end if;
    if app.feature_on(v_rest, p_module) then raise exception 'That module is already on.'; end if;
  elsif p_kind = 'outlet' then
    if coalesce(trim(p_outlet_name), '') = '' then raise exception 'Enter the new outlet''s name.'; end if;
  else
    raise exception 'Unknown request.';
  end if;
  if exists (select 1 from public.plan_requests where restaurant_id = v_rest and kind = p_kind
               and coalesce(module_key, '') = coalesce(p_module, '') and status in ('requested', 'approved')
               and p_kind <> 'outlet') then
    raise exception 'This request is already with the SNA team.';
  end if;
  insert into public.plan_requests (restaurant_id, kind, module_key, outlet_name, outlet_city, note, requested_by_user)
  values (v_rest, p_kind, case when p_kind = 'module' then p_module end, left(trim(p_outlet_name), 80),
          left(trim(p_outlet_city), 60), left(trim(p_note), 300), app.current_user_id())
  returning id into v_id;
  perform app.log_plan(v_rest, 'request.' || p_kind, jsonb_build_object('request', v_id, 'module', p_module, 'outlet', p_outlet_name));
  return v_id;
end $$;

create or replace function public.cancel_plan_request(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not app.is_owner() then raise exception 'Only the owner can cancel plan requests.'; end if;
  update public.plan_requests set status = 'cancelled'
   where id = p_id and restaurant_id = app.current_restaurant_id() and status = 'requested';
  if not found then raise exception 'This request can no longer be cancelled.'; end if;
  perform app.log_plan(app.current_restaurant_id(), 'request.cancelled', jsonb_build_object('request', p_id));
end $$;

-- ---------- SNA console ----------
create or replace function public.sna_me() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('id', s.id, 'full_name', s.full_name, 'email', s.email, 'role', s.role)
    from public.sna_staff s where s.auth_user_id = auth.uid() and s.is_active
$$;

create or replace function app.monthly_charge(p_restaurant uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select monthly_price from public.plan_prices where item = r.edition and currency_code = r.currency_code), 0)
           * greatest((select count(*) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null), 1)
       + coalesce((select sum(pp.monthly_price) from public.restaurant_modules rm
                     join public.plan_prices pp on pp.item = rm.module_key and pp.currency_code = r.currency_code
                    where rm.restaurant_id = r.id), 0)
    from public.restaurants r where r.id = p_restaurant
$$;

create or replace function public.sna_restaurants(p_search text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  return (select coalesce(jsonb_agg(x order by x->>'trading_name'), '[]'::jsonb) from (
    select jsonb_build_object('id', r.id, 'trading_name', r.trading_name, 'legal_name', r.legal_name,
             'country_code', r.country_code, 'currency', r.currency_code, 'edition', r.edition, 'created_at', r.created_at,
             'outlets', (select count(*) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
             'modules', (select coalesce(jsonb_agg(rm.module_key order by rm.module_key), '[]'::jsonb) from public.restaurant_modules rm where rm.restaurant_id = r.id),
             'open_requests', (select count(*) from public.plan_requests q where q.restaurant_id = r.id and q.status in ('requested', 'approved')),
             'owner_email', (select u.email from public.users u join public.roles ro on ro.id = u.role_id
                              where u.restaurant_id = r.id and ro.name = 'Owner' and ro.is_system and u.deleted_at is null
                              order by u.created_at limit 1),
             'monthly', app.monthly_charge(r.id)) as x
      from public.restaurants r
     where r.deleted_at is null
       and (coalesce(trim(p_search), '') = '' or r.trading_name ilike '%' || trim(p_search) || '%'
            or r.legal_name ilike '%' || trim(p_search) || '%')
     limit 500) s);
end $$;

create or replace function public.sna_restaurant(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.restaurants%rowtype;
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  select * into r from public.restaurants where id = p_id;
  if not found then raise exception 'Restaurant not found.'; end if;
  return jsonb_build_object(
    'id', r.id, 'trading_name', r.trading_name, 'legal_name', r.legal_name, 'country_code', r.country_code,
    'currency', r.currency_code, 'edition', r.edition, 'timezone', r.timezone, 'created_at', r.created_at,
    'contact_email', r.contact_email, 'contact_phone', r.contact_phone,
    'monthly', app.monthly_charge(r.id),
    'modules', (select jsonb_agg(jsonb_build_object('key', m.key, 'name', m.name, 'kind', m.kind, 'on', app.feature_on(r.id, m.key),
                  'price', (select monthly_price from public.plan_prices where item = m.key and currency_code = r.currency_code))
                  order by m.display_order) from public.modules m),
    'prices', (select coalesce(jsonb_object_agg(item, monthly_price), '{}'::jsonb) from public.plan_prices where currency_code = r.currency_code),
    'branches', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'city', b.city, 'is_active', b.is_active)
                  order by b.created_at), '[]'::jsonb) from public.branches b where b.restaurant_id = r.id and b.deleted_at is null),
    'requests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'kind', q.kind, 'module_key', q.module_key, 'outlet_name', q.outlet_name,
                  'outlet_city', q.outlet_city, 'note', q.note, 'status', q.status, 'created_at', q.created_at, 'decision_note', q.decision_note)
                  order by q.created_at desc), '[]'::jsonb) from public.plan_requests q where q.restaurant_id = r.id),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('event', e.event, 'details', e.details, 'created_at', e.created_at,
                  'by', coalesce((select full_name from public.sna_staff where id = e.staff_id), (select full_name from public.users where id = e.user_id)))
                  order by e.created_at desc), '[]'::jsonb)
                 from (select * from public.subscription_events where restaurant_id = r.id order by created_at desc limit 50) e));
end $$;

create or replace function public.sna_requests(p_status text default 'open') returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'restaurant_id', q.restaurant_id, 'trading_name', r.trading_name,
            'kind', q.kind, 'module_key', q.module_key, 'outlet_name', q.outlet_name, 'outlet_city', q.outlet_city, 'note', q.note,
            'status', q.status, 'created_at', q.created_at, 'decision_note', q.decision_note) order by q.created_at), '[]'::jsonb)
    from public.plan_requests q join public.restaurants r on r.id = q.restaurant_id
   where case when p_status = 'open' then q.status in ('requested', 'approved') else q.status = p_status end);
end $$;

create or replace function public.sna_set_edition(p_restaurant uuid, p_edition text, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old text; v_n int;
begin
  perform app.sna_require(array['sales']);
  if p_edition not in ('basic', 'professional') then raise exception 'Unknown edition.'; end if;
  select edition into v_old from public.restaurants where id = p_restaurant for update;
  if not found then raise exception 'Restaurant not found.'; end if;
  if v_old = p_edition then return; end if;
  if p_edition = 'basic' then
    select count(*) into v_n from public.branches where restaurant_id = p_restaurant and deleted_at is null;
    if v_n > 1 then raise exception 'This restaurant has % outlets. Basic allows one — close the extra outlets first.', v_n; end if;
  end if;
  update public.restaurants set edition = p_edition where id = p_restaurant;
  update public.plan_requests set status = 'done', decided_by = app.sna_staff_id(), decided_at = now(), done_by = app.sna_staff_id(), done_at = now()
   where restaurant_id = p_restaurant and kind = 'upgrade' and status in ('requested', 'approved') and p_edition = 'professional';
  perform app.log_plan(p_restaurant, 'edition.changed', jsonb_build_object('from', v_old, 'to', p_edition, 'note', p_note));
end $$;

create or replace function public.sna_set_module(p_restaurant uuid, p_module text, p_on boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.sna_require(array['sales']);
  if not exists (select 1 from public.modules where key = p_module and kind = 'addon') then raise exception 'Unknown add-on module.'; end if;
  if not exists (select 1 from public.restaurants where id = p_restaurant) then raise exception 'Restaurant not found.'; end if;
  if p_on then
    insert into public.restaurant_modules (restaurant_id, module_key, enabled_by) values (p_restaurant, p_module, app.sna_staff_id())
    on conflict do nothing;
    if not found then return; end if;
    update public.plan_requests set status = 'done', decided_by = app.sna_staff_id(), decided_at = now(), done_by = app.sna_staff_id(), done_at = now()
     where restaurant_id = p_restaurant and kind = 'module' and module_key = p_module and status in ('requested', 'approved');
  else
    delete from public.restaurant_modules where restaurant_id = p_restaurant and module_key = p_module;
    if not found then return; end if;
  end if;
  perform app.log_plan(p_restaurant, case when p_on then 'module.on' else 'module.off' end, jsonb_build_object('module', p_module, 'note', p_note));
end $$;

create or replace function public.sna_decide_request(p_id uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare q public.plan_requests%rowtype;
begin
  perform app.sna_require(array['sales']);
  select * into q from public.plan_requests where id = p_id for update;
  if not found or q.status <> 'requested' then raise exception 'This request is not waiting for a decision.'; end if;
  if not p_approve then
    update public.plan_requests set status = 'rejected', decided_by = app.sna_staff_id(), decided_at = now(), decision_note = left(p_note, 300) where id = p_id;
    perform app.log_plan(q.restaurant_id, 'request.rejected', jsonb_build_object('request', p_id, 'note', p_note));
    return;
  end if;
  update public.plan_requests set status = 'approved', decided_by = app.sna_staff_id(), decided_at = now(), decision_note = left(p_note, 300) where id = p_id;
  perform app.log_plan(q.restaurant_id, 'request.approved', jsonb_build_object('request', p_id, 'kind', q.kind, 'note', p_note));
  -- Upgrade and module requests take effect at once; an outlet waits for the implementer.
  if q.kind = 'upgrade' then perform public.sna_set_edition(q.restaurant_id, 'professional', p_note);
  elsif q.kind = 'module' then perform public.sna_set_module(q.restaurant_id, q.module_key, true, p_note);
  end if;
end $$;

create or replace function public.sna_create_outlet(p_request uuid, p_name text, p_code text, p_city text,
  p_address text default null, p_phone text default null, p_timezone text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare q public.plan_requests%rowtype; v_rest public.restaurants%rowtype; v_first public.branches%rowtype; v_id uuid;
begin
  perform app.sna_require(array['implementer']);
  select * into q from public.plan_requests where id = p_request for update;
  if not found or q.kind <> 'outlet' then raise exception 'Outlet request not found.'; end if;
  if q.status <> 'approved' then raise exception 'Sales must approve this outlet before it is added.'; end if;
  select * into v_rest from public.restaurants where id = q.restaurant_id;
  if v_rest.edition <> 'professional' then raise exception 'Upgrade the restaurant to Professional before adding outlets.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the outlet name.'; end if;
  if coalesce(trim(p_code), '') !~ '^[A-Za-z0-9]{2,4}$' then raise exception 'The outlet code is 2–4 letters or digits (it starts every bill number).'; end if;
  if exists (select 1 from public.branches where restaurant_id = q.restaurant_id and upper(code) = upper(trim(p_code)) and deleted_at is null) then
    raise exception 'Another outlet already uses the code %.', upper(trim(p_code));
  end if;
  select * into v_first from public.branches where restaurant_id = q.restaurant_id and deleted_at is null order by created_at limit 1;
  insert into public.branches (restaurant_id, name, code, address_line1, city, country_code, phone, timezone, is_active)
  values (q.restaurant_id, left(trim(p_name), 80), upper(trim(p_code)), nullif(trim(p_address), ''), nullif(trim(p_city), ''),
          v_rest.country_code, nullif(trim(p_phone), ''), coalesce(nullif(p_timezone, ''), v_first.timezone, v_rest.timezone), true)
  returning id into v_id;
  insert into public.branch_settings (branch_id, restaurant_id, receipt_header, receipt_footer, service_charge_percent, cash_rounding_mode,
      default_order_type, auto_print_kot, service_charge_taxable, service_charge_default_on, service_charge_label, rounding_cash_only)
  select v_id, s.restaurant_id, s.receipt_header, s.receipt_footer, s.service_charge_percent, s.cash_rounding_mode,
         s.default_order_type, s.auto_print_kot, s.service_charge_taxable, s.service_charge_default_on, s.service_charge_label, s.rounding_cash_only
    from public.branch_settings s where s.branch_id = v_first.id;
  if not found then
    insert into public.branch_settings (branch_id, restaurant_id) values (v_id, q.restaurant_id);
  end if;
  -- Owners can work in every outlet.
  insert into public.user_branches (user_id, branch_id, restaurant_id)
  select u.id, v_id, q.restaurant_id from public.users u join public.roles r on r.id = u.role_id
   where u.restaurant_id = q.restaurant_id and r.name = 'Owner' and r.is_system and u.deleted_at is null
  on conflict do nothing;
  update public.plan_requests set status = 'done', done_by = app.sna_staff_id(), done_at = now(), branch_id = v_id where id = p_request;
  perform app.log_plan(q.restaurant_id, 'outlet.created', jsonb_build_object('request', p_request, 'branch', v_id, 'name', p_name, 'code', upper(trim(p_code))));
  return v_id;
end $$;

create or replace function public.sna_add_request(p_restaurant uuid, p_kind text, p_module text default null,
  p_outlet_name text default null, p_outlet_city text default null, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform app.sna_require(array['sales']);
  if p_kind <> 'outlet' then raise exception 'Use the edition and module switches for upgrades and modules.'; end if;
  if coalesce(trim(p_outlet_name), '') = '' then raise exception 'Enter the new outlet''s name.'; end if;
  insert into public.plan_requests (restaurant_id, kind, outlet_name, outlet_city, note, requested_by_staff)
  values (p_restaurant, 'outlet', left(trim(p_outlet_name), 80), left(trim(p_outlet_city), 60), left(trim(p_note), 300), app.sna_staff_id())
  returning id into v_id;
  perform app.log_plan(p_restaurant, 'request.outlet', jsonb_build_object('request', v_id, 'outlet', p_outlet_name, 'by_sna', true));
  return v_id;
end $$;

create or replace function public.sna_staff_list() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.sna_require(array[]::text[]);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'email', email, 'role', role,
            'is_active', is_active, 'created_at', created_at) order by full_name), '[]'::jsonb) from public.sna_staff);
end $$;

create or replace function public.sna_save_staff(p_email text, p_full_name text, p_role text, p_active boolean default true) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_auth uuid; v_id uuid; v_me uuid;
begin
  v_me := app.sna_require(array[]::text[]);  -- admin only
  if p_role not in ('admin', 'sales', 'implementer', 'support') then raise exception 'Choose a role.'; end if;
  if coalesce(trim(p_full_name), '') = '' then raise exception 'Enter the name.'; end if;
  select id into v_auth from auth.users where lower(email) = lower(trim(p_email));
  if v_auth is null then
    raise exception 'No SNA POS account uses %. Ask them to sign up first (without creating a restaurant), then add them.', trim(p_email);
  end if;
  select id into v_id from public.sna_staff where auth_user_id = v_auth;
  if v_id = v_me and (not p_active or p_role <> 'admin') then raise exception 'You cannot remove your own admin access.'; end if;
  insert into public.sna_staff (auth_user_id, full_name, email, role, is_active)
  values (v_auth, trim(p_full_name), lower(trim(p_email)), p_role, p_active)
  on conflict (auth_user_id) do update set full_name = excluded.full_name, role = excluded.role, is_active = excluded.is_active
  returning id into v_id;
  perform app.log_plan(null, 'sna_staff.saved', jsonb_build_object('staff', v_id, 'email', lower(trim(p_email)), 'role', p_role, 'active', p_active));
  return v_id;
end $$;

create or replace function public.sna_set_price(p_item text, p_currency text, p_price numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.sna_require(array[]::text[]);  -- admin only
  if p_item not in ('basic', 'professional') and not exists (select 1 from public.modules where key = p_item and kind = 'addon') then
    raise exception 'Unknown plan item.';
  end if;
  if p_price is not null and (p_price < 0 or p_price > 1000000) then raise exception 'Enter a sensible price.'; end if;
  insert into public.plan_prices (item, currency_code, monthly_price) values (p_item, upper(p_currency), p_price)
  on conflict (item, currency_code) do update set monthly_price = excluded.monthly_price;
  perform app.log_plan(null, 'price.set', jsonb_build_object('item', p_item, 'currency', upper(p_currency), 'price', p_price));
end $$;

revoke all on function public.my_plan(), public.request_plan_change(text,text,text,text,text), public.cancel_plan_request(uuid),
  public.sna_me(), public.sna_restaurants(text), public.sna_restaurant(uuid), public.sna_requests(text),
  public.sna_set_edition(uuid,text,text), public.sna_set_module(uuid,text,boolean,text), public.sna_decide_request(uuid,boolean,text),
  public.sna_create_outlet(uuid,text,text,text,text,text,text), public.sna_add_request(uuid,text,text,text,text,text),
  public.sna_staff_list(), public.sna_save_staff(text,text,text,boolean), public.sna_set_price(text,text,numeric) from public, anon;
grant execute on function public.my_plan(), public.request_plan_change(text,text,text,text,text), public.cancel_plan_request(uuid),
  public.sna_me(), public.sna_restaurants(text), public.sna_restaurant(uuid), public.sna_requests(text),
  public.sna_set_edition(uuid,text,text), public.sna_set_module(uuid,text,boolean,text), public.sna_decide_request(uuid,boolean,text),
  public.sna_create_outlet(uuid,text,text,text,text,text,text), public.sna_add_request(uuid,text,text,text,text,text),
  public.sna_staff_list(), public.sna_save_staff(text,text,text,boolean), public.sna_set_price(text,text,numeric) to authenticated;
revoke all on function app.feature_on(uuid,text), app.require_feature(text), app.sna_require(text[]), app.sna_staff_id(),
  app.log_plan(uuid,text,jsonb), app.monthly_charge(uuid), app.basic_limits() from public, anon;

-- First SNA admin: the Founder's account (the owner of the first restaurant).
insert into public.sna_staff (auth_user_id, full_name, email, role)
select u.auth_user_id, u.full_name, coalesce(u.email::text, au.email), 'admin'
  from public.users u join public.roles r on r.id = u.role_id and r.name = 'Owner' and r.is_system
  join auth.users au on au.id = u.auth_user_id
 order by u.created_at limit 1
on conflict do nothing;
