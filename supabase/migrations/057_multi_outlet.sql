-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928103339, name '057_multi_outlet'. This is the SQL that actually ran.
-- The text previously in git under this number differed from what ran (see git history before the commit that added this header).

alter table public.users
  add column if not exists current_branch_id uuid references public.branches(id),
  add column if not exists all_outlets boolean not null default false;
alter table public.branches add column if not exists is_central_kitchen boolean not null default false;

create or replace function app.can_use_branch(p_branch uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.branches b
     where b.id = p_branch and b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null and b.is_active
       and (app.is_owner()
            or exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id() and ub.branch_id = b.id)
            or not exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id())))
$$;

create or replace function app.current_branch_id() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select d.branch_id from public.devices d where d.id = app.device_id()),
    (select u.current_branch_id from public.users u
      where u.id = app.current_user_id() and u.current_branch_id is not null and app.can_use_branch(u.current_branch_id)),
    (select b.id from public.branches b
      where b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null and app.can_use_branch(b.id)
      order by b.created_at limit 1),
    (select b.id from public.branches b
      where b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null
      order by b.created_at limit 1))
$$;

create or replace function app.report_branch() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when app.device_id() is null
     and (select u.all_outlets from public.users u where u.id = app.current_user_id())
     and (app.is_owner() or not exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id()))
    then null
    else app.current_branch_id() end
$$;

create or replace function app.in_scope(p_branch uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select app.report_branch() is null or p_branch = app.report_branch()
$$;

create or replace function public.my_outlets() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'current', app.current_branch_id(),
    'all_outlets', app.report_branch() is null,
    'can_all', app.device_id() is null and (app.is_owner() or not exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id())),
    'fixed', app.device_id() is not null,
    'outlets', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'code', b.code, 'city', b.city,
                   'central_kitchen', b.is_central_kitchen) order by b.created_at), '[]'::jsonb)
                  from public.branches b where b.restaurant_id = app.current_restaurant_id() and b.deleted_at is null and app.can_use_branch(b.id)))
$$;

create or replace function public.set_current_outlet(p_branch uuid, p_all boolean default false) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if app.current_user_id() is null then raise exception 'You are not signed in.'; end if;
  if app.device_id() is not null then raise exception 'A counter tablet always works in its own outlet.'; end if;
  if not app.can_use_branch(p_branch) then raise exception 'You do not work in that outlet.'; end if;
  if p_all and not (app.is_owner() or not exists (select 1 from public.user_branches ub where ub.user_id = app.current_user_id())) then
    raise exception 'Only the owner can see all outlets together.';
  end if;
  update public.users set current_branch_id = p_branch, all_outlets = coalesce(p_all, false) where id = app.current_user_id();
end $$;

create or replace function public.set_user_outlets(p_user_id uuid, p_branches uuid[]) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_permission('user.manage');
  perform app.require_feature('multi_outlet');
  if not exists (select 1 from public.users where id = p_user_id and restaurant_id = v_rest) then raise exception 'Person not found.'; end if;
  if coalesce(array_length(p_branches, 1), 0) = 0 then raise exception 'Choose at least one outlet.'; end if;
  if exists (select 1 from unnest(p_branches) x where not exists (select 1 from public.branches b where b.id = x and b.restaurant_id = v_rest and b.deleted_at is null)) then
    raise exception 'An outlet in the list does not exist.';
  end if;
  delete from public.user_branches where user_id = p_user_id and not (branch_id = any(p_branches));
  insert into public.user_branches (user_id, branch_id, restaurant_id)
  select p_user_id, x, v_rest from unnest(p_branches) x on conflict do nothing;
  perform app.audit('user.outlets', 'users', p_user_id, jsonb_build_object('outlets', p_branches));
end $$;

do $$
declare t text;
begin
  foreach t in array array['orders', 'dining_tables', 'floors', 'kitchen_tickets', 'shifts', 'business_days', 'credit_notes',
                           'printers', 'stock_movements', 'branch_settings', 'devices']
  loop
    execute format('drop policy if exists tenant_read on public.%I', t);
    execute format('create policy tenant_read on public.%I for select to authenticated using (restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id()))', t);
  end loop;
  foreach t in array array['dining_tables', 'floors', 'printers']
  loop
    execute format('drop policy if exists perm_insert on public.%I', t);
    execute format('create policy perm_insert on public.%I for insert to authenticated with check (restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id()) and (select app.has_permission(''settings.manage'')))', t);
    execute format('drop policy if exists perm_update on public.%I', t);
    execute format('create policy perm_update on public.%I for update to authenticated using (restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id()) and (select app.has_permission(''settings.manage''))) with check (restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id()))', t);
    execute format('drop policy if exists perm_delete on public.%I', t);
    execute format('create policy perm_delete on public.%I for delete to authenticated using (restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id()) and (select app.has_permission(''settings.manage'')))', t);
  end loop;
end $$;

create table public.branch_prices (
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid not null references public.branches(id),
  product_id uuid not null references public.products(id),
  price numeric(12,2) check (price is null or price >= 0),
  is_available boolean,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.users(id),
  primary key (branch_id, product_id)
);
alter table public.branch_prices enable row level security;
revoke all on public.branch_prices from anon, authenticated;
grant select on public.branch_prices to authenticated;
create policy tenant_read on public.branch_prices for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));

create or replace function public.set_outlet_price(p_product_id uuid, p_branch_id uuid, p_price numeric, p_available boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_old public.branch_prices%rowtype; v_prod public.products%rowtype;
begin
  perform app.require_feature('multi_outlet');
  select * into v_prod from public.products where id = p_product_id and restaurant_id = v_rest and deleted_at is null;
  if not found then raise exception 'Menu item not found.'; end if;
  if not exists (select 1 from public.branches where id = p_branch_id and restaurant_id = v_rest and deleted_at is null) then
    raise exception 'Outlet not found.';
  end if;
  select * into v_old from public.branch_prices where branch_id = p_branch_id and product_id = p_product_id;
  if p_price is distinct from v_old.price then perform app.require_permission('menu.price_change'); end if;
  if p_available is distinct from v_old.is_available then perform app.require_permission('menu.manage'); end if;
  if p_price is not null and (p_price < 0 or p_price > 10000000) then raise exception 'Enter a sensible price.'; end if;
  if p_price is null and p_available is null then
    delete from public.branch_prices where branch_id = p_branch_id and product_id = p_product_id;
  else
    insert into public.branch_prices (restaurant_id, branch_id, product_id, price, is_available, updated_by)
    values (v_rest, p_branch_id, p_product_id, p_price, p_available, app.current_user_id())
    on conflict (branch_id, product_id) do update set price = excluded.price, is_available = excluded.is_available,
      updated_at = now(), updated_by = excluded.updated_by;
  end if;
  perform app.audit('menu.outlet_price', 'products', p_product_id,
    jsonb_build_object('branch', p_branch_id, 'price', p_price, 'available', p_available),
    jsonb_build_object('price', v_old.price, 'available', v_old.is_available));
end $$;

do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('app.bill_input(uuid,uuid,jsonb,numeric,boolean,jsonb)'::regprocedure);
  v_def := replace(v_def, 'v_text text; g record;', 'v_text text; g record; v_bp public.branch_prices%rowtype;');
  v_def := replace(v_def, '    if not v_product.is_available then raise exception',
    E'    select * into v_bp from public.branch_prices where branch_id = p_branch and product_id = v_product.id;\n' ||
    E'    if found then\n      v_product.price := coalesce(v_bp.price, v_product.price);\n' ||
    E'      v_product.is_available := v_product.is_available and coalesce(v_bp.is_available, true);\n    end if;\n' ||
    '    if not v_product.is_available then raise exception');
  if position('v_bp.price' in v_def) = 0 then raise exception 'bill_input patch failed'; end if;
  execute v_def;

  v_def := pg_get_functiondef('public.offline_snapshot(text)'::regprocedure);
  v_def := replace(v_def, '''price'', p.price,',
    '''price'', coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), p.price),');
  v_def := replace(v_def, 'p.deleted_at is null and p.is_available and c.deleted_at is null',
    'p.deleted_at is null and p.is_available and c.deleted_at is null and coalesce((select bp.is_available from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = p.id), true)');
  if position('branch_prices' in v_def) = 0 then raise exception 'offline_snapshot patch failed'; end if;
  execute v_def;

  v_def := pg_get_functiondef('public.sync_offline_bill(jsonb)'::regprocedure);
  v_def := replace(v_def, 'and v_price <> v_prod.price + v_delta) then',
    'and v_price <> v_prod.price + v_delta and v_price <> coalesce((select bp.price from public.branch_prices bp where bp.branch_id = v_branch and bp.product_id = v_prod.id), -1) + v_delta) then');
  if position('branch_prices' in v_def) = 0 then raise exception 'sync_offline_bill patch failed'; end if;
  execute v_def;

  v_def := pg_get_functiondef('public.sales_report(date,date)'::regprocedure);
  v_def := replace(v_def, 'where restaurant_id = v_rest and created_at >= v_start and created_at < v_end',
                          'where restaurant_id = v_rest and app.in_scope(branch_id) and created_at >= v_start and created_at < v_end');
  v_def := replace(v_def, 'from public.refunds r where r.restaurant_id = v_rest and',
                          'from public.refunds r where r.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = r.order_id)) and');
  if position('in_scope' in v_def) = 0 then raise exception 'sales_report patch failed'; end if;
  execute v_def;

  v_def := pg_get_functiondef('public.settlement_report(date,date)'::regprocedure);
  v_def := replace(v_def, 'where p.restaurant_id = v_rest and p.created_at',
                          'where p.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = p.order_id)) and p.created_at');
  v_def := replace(v_def, 'where r.restaurant_id = v_rest and r.created_at',
                          'where r.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = p.order_id)) and r.created_at');
  v_def := replace(v_def, 'where o.restaurant_id = v_rest and o.status = ''voided''',
                          'where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.status = ''voided''');
  if position('in_scope' in v_def) = 0 then raise exception 'settlement patch failed'; end if;
  execute v_def;

  v_def := pg_get_functiondef('public.gst_register(date,date)'::regprocedure);
  v_def := replace(v_def, 'where o.restaurant_id = v_rest and o.business_date', 'where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.business_date');
  v_def := replace(v_def, 'cn.restaurant_id = v_rest and', 'cn.restaurant_id = v_rest and app.in_scope(cn.branch_id) and');
  if position('in_scope' in v_def) = 0 then raise exception 'gst patch failed'; end if;
  execute v_def;

  v_def := pg_get_functiondef('public.accounting_journal(date,date)'::regprocedure);
  v_def := replace(v_def, 'where o.restaurant_id = v_rest and o.business_date', 'where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.business_date');
  v_def := replace(v_def, 'cn.restaurant_id = v_rest and', 'cn.restaurant_id = v_rest and app.in_scope(cn.branch_id) and');
  if position('in_scope' in v_def) = 0 then raise exception 'journal patch failed'; end if;
  execute v_def;
end $$;

create or replace function public.outlet_comparison(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_permission('report.view_sales');
  perform app.require_feature('multi_outlet');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a valid date range (one year or less).'; end if;
  return (select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc), '[]'::jsonb) from (
    select jsonb_build_object('outlet', b.name, 'code', b.code,
      'bills', count(o.id) filter (where o.status = 'completed'),
      'total', coalesce(sum(o.grand_total) filter (where o.status = 'completed'), 0),
      'average', coalesce(round(avg(o.grand_total) filter (where o.status = 'completed'), 2), 0),
      'discounts', coalesce(sum(o.discount_total) filter (where o.status = 'completed'), 0),
      'voids', count(o.id) filter (where o.status = 'voided'),
      'void_value', coalesce(sum(o.grand_total) filter (where o.status = 'voided'), 0)) x
      from public.branches b
      left join public.orders o on o.branch_id = b.id and o.merged_into is null and o.business_date between p_from and p_to
     where b.restaurant_id = v_rest and b.deleted_at is null and app.can_use_branch(b.id)
     group by b.id, b.name, b.code) z);
end $$;

alter table public.stock_movements drop constraint stock_movements_kind_check;
alter table public.stock_movements add constraint stock_movements_kind_check
  check (kind in ('purchase', 'sale', 'returned', 'wastage', 'count', 'adjust', 'transfer_in', 'transfer_out'));
alter table public.stock_movements add column if not exists transfer_id uuid;

create or replace function public.transfer_stock(p_ingredient_id uuid, p_qty numeric, p_to_branch uuid, p_note text default null) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_from uuid := app.current_branch_id();
  v_ing public.ingredients%rowtype; v_now numeric; v_id uuid := gen_random_uuid(); v_from_name text; v_to_name text;
begin
  perform app.require_feature('central_kitchen');
  perform app.require_feature('stock');
  select * into v_ing from public.ingredients where id = p_ingredient_id and restaurant_id = v_rest;
  if not found then raise exception 'Ingredient not found.'; end if;
  if p_to_branch = v_from then raise exception 'Choose another outlet to send to.'; end if;
  select name into v_to_name from public.branches where id = p_to_branch and restaurant_id = v_rest and deleted_at is null;
  if v_to_name is null then raise exception 'Outlet not found.'; end if;
  select name into v_from_name from public.branches where id = v_from;
  if p_qty is null or p_qty <= 0 then raise exception 'Enter a quantity.'; end if;
  perform pg_advisory_xact_lock(hashtext('stock:' || v_from::text || ':' || v_ing.id::text));
  select coalesce(sum(qty), 0) into v_now from public.stock_movements where branch_id = v_from and ingredient_id = v_ing.id;
  if p_qty > v_now then raise exception 'Only % % of % in stock here.', v_now, v_ing.unit, v_ing.name; end if;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, transfer_id) values
    (v_rest, v_from, v_ing.id, 'transfer_out', -p_qty, v_ing.cost_per_unit, left('To ' || v_to_name || coalesce(': ' || nullif(trim(p_note), ''), ''), 200), v_user, v_id),
    (v_rest, p_to_branch, v_ing.id, 'transfer_in', p_qty, v_ing.cost_per_unit, left('From ' || v_from_name || coalesce(': ' || nullif(trim(p_note), ''), ''), 200), v_user, v_id);
  perform app.audit('stock.transfer', 'ingredients', v_ing.id, jsonb_build_object('qty', p_qty, 'from', v_from, 'to', p_to_branch, 'transfer', v_id));
  return v_id;
end $$;

do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('public.stock_report(date,date)'::regprocedure);
  v_def := replace(v_def, '''count_diff'', coalesce(',
    '''transfers'', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id' ||
    ' and m.kind in (''transfer_in'', ''transfer_out'') and m.created_at >= v_start and m.created_at < v_end), 0),' || E'\n      ' ||
    '''count_diff'', coalesce(');
  if position('transfers' in v_def) = 0 then raise exception 'stock_report patch failed'; end if;
  execute v_def;
end $$;

create or replace function public.set_central_kitchen(p_branch uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('central_kitchen');
  update public.branches set is_central_kitchen = p_on where id = p_branch and restaurant_id = app.current_restaurant_id() and deleted_at is null;
  if not found then raise exception 'Outlet not found.'; end if;
  perform app.audit('outlet.central_kitchen', 'branches', p_branch, jsonb_build_object('on', p_on));
end $$;

create or replace view public.v_current_user as
 select u.id as user_id, u.restaurant_id, u.full_name, u.email, u.employee_code,
        r.id as role_id, r.name as role_name, res.trading_name, res.country_code, res.currency_code, res.timezone,
        (select coalesce(array_agg(rp.permission_key order by rp.permission_key), '{}'::text[])
           from public.role_permissions rp where rp.role_id = r.id) as permissions,
        u.must_change_password,
        (select d.name from public.devices d where d.id = app.device_id()) as device_name,
        res.edition,
        (select coalesce(array_agg(m.key order by m.key), '{}'::text[])
           from public.modules m where app.feature_on(res.id, m.key)) as features,
        (app.sna_staff_id() is not null) as is_sna_staff,
        app.current_branch_id() as branch_id,
        (select b.name from public.branches b where b.id = app.current_branch_id()) as branch_name,
        (select count(*)::int from public.branches b where b.restaurant_id = res.id and b.deleted_at is null) as outlet_count
   from public.users u
   join public.roles r on r.id = u.role_id
   join public.restaurants res on res.id = u.restaurant_id
  where u.id = app.current_user_id();

grant execute on function app.current_branch_id(), app.can_use_branch(uuid), app.report_branch(), app.in_scope(uuid) to authenticated;
revoke all on function public.my_outlets(), public.set_current_outlet(uuid,boolean), public.set_user_outlets(uuid,uuid[]),
  public.set_outlet_price(uuid,uuid,numeric,boolean), public.outlet_comparison(date,date),
  public.transfer_stock(uuid,numeric,uuid,text), public.set_central_kitchen(uuid,boolean) from public, anon;
grant execute on function public.my_outlets(), public.set_current_outlet(uuid,boolean), public.set_user_outlets(uuid,uuid[]),
  public.set_outlet_price(uuid,uuid,numeric,boolean), public.outlet_comparison(date,date),
  public.transfer_stock(uuid,numeric,uuid,text), public.set_central_kitchen(uuid,boolean) to authenticated;
