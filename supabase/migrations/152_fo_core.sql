-- 152: Front Office core (SNA Hospitality, module 1 of 6). Additive only: no existing table, function or policy is changed.
--
-- Model
--   A hotel is a restaurant row (the tenant). A property is a branch row. Rooms belong to a branch, guests and room types to
--   the restaurant, so a group can share a guest list across properties and keep its room inventory per property.
--   The business date is app.business_today(branch) -- the SAME date the POS uses. Front Office does NOT keep a date pointer of
--   its own: if it did, a room charge and a restaurant bill posted on the same evening could land on different days and the MIS
--   module would never reconcile. The night audit (154) is a per-date action, not a clock the user winds forward.
--   Folio payments reuse public.payment_methods, so cash/card/UPI mean the same thing in the POS and at reception.
--
-- Rights: fo.view (see the board, folios and reports), fo.manage (reservations, check-in, charges, payments, check-out),
--   fo.housekeeping (room clean/dirty/out-of-service), fo.night_audit (run the audit). fo.manage implies fo.view everywhere
--   ("fo.view OR fo.manage"), so a custom role with only fo.manage keeps working. Owner and Manager get all four.
--
-- Gating: module key 'front_office', kind 'addon' ON PURPOSE. app.feature_on treats a 'professional' module as on for every
--   restaurant on the Professional edition, which would switch Front Office on for every existing POS customer at once. An
--   add-on needs an explicit public.restaurant_modules row, so a restaurant sees nothing until a hotel is actually sold one.
--
-- Writes: these tables have SELECT only for `authenticated` and no write policy. Every change goes through a SECURITY DEFINER
--   function (153 for the stay lifecycle, 154 for the night audit), same rule as migration 113.
--
-- Tax defaults (5% to 7500, 18% above) follow Indian GST room-tariff slabs. NOT yet confirmed by a tax adviser -- they are
--   configuration in fo_branch_settings, changeable per property without a migration.
-- Safe to run again.

-- ---------------------------------------------------------------- 1. rights
insert into public.permissions (key, description, is_sensitive) values
  ('fo.view',        'See the room board, guest folios and front office reports', false),
  ('fo.manage',      'Take reservations, check guests in and out, post charges and payments', true),
  ('fo.housekeeping','Set rooms clean, dirty or out of service', false),
  ('fo.night_audit', 'Run the night audit', true)
on conflict (key) do nothing;

-- Owner and Manager (and any custom role that already holds every right) get the four.
insert into public.role_permissions (role_id, permission_key)
select r.id, k.key from public.roles r
 cross join (values ('fo.view'), ('fo.manage'), ('fo.housekeeping'), ('fo.night_audit')) k(key)
 where r.is_system and r.name in ('Owner', 'Manager')
on conflict do nothing;

-- Restaurants created later need nothing here: app.create_restaurant_with_owner grants the Owner role every row of
-- public.permissions and the Manager role all but three, so the four rights above are picked up at creation. A trigger
-- would collide with those inserts. Cashier, Steward and Waiter get no front office right, which is the intention.
drop trigger if exists trg_grant_fo_rights on public.roles;
drop function if exists app.trg_grant_fo_rights();

-- ---------------------------------------------------------------- 2. module
insert into public.modules (key, name, description, kind, display_order) values
  ('front_office', 'Front office and housekeeping', 'Rooms, reservations, check-in, guest folios, night audit', 'addon', 25)
on conflict (key) do nothing;

-- ---------------------------------------------------------------- 3. helpers
-- One right or the other; the error names the first one, same shape as app.require_stock_any (143).
create or replace function app.require_fo(p_keys text[]) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare k text;
begin
  if app.current_restaurant_id() is null then raise exception 'You are not signed in.'; end if;
  perform app.require_feature('front_office');
  foreach k in array p_keys loop
    if app.has_permission(k) then return app.current_user_id(); end if;
  end loop;
  raise exception 'Your role does not allow this action (%).', p_keys[1];
end $$;
revoke all on function app.require_fo(text[]) from public, anon, authenticated;

-- ---------------------------------------------------------------- 4. tables
create table if not exists public.fo_branch_settings (
  branch_id uuid primary key references public.branches(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  room_tax_pct numeric(5,2) not null default 5.00 check (room_tax_pct >= 0 and room_tax_pct <= 100),
  room_tax_pct_high numeric(5,2) not null default 18.00 check (room_tax_pct_high >= 0 and room_tax_pct_high <= 100),
  room_tax_threshold numeric(12,2) not null default 7500.00 check (room_tax_threshold >= 0),
  other_tax_pct numeric(5,2) not null default 5.00 check (other_tax_pct >= 0 and other_tax_pct <= 100),
  check_in_time time not null default '12:00',
  check_out_time time not null default '11:00',
  updated_at timestamptz not null default now(),
  unique (restaurant_id, branch_id)
);

create table if not exists public.fo_room_types (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  code text not null,
  name text not null,
  base_rate numeric(12,2) not null default 0 check (base_rate >= 0),
  max_occupancy int not null default 2 check (max_occupancy between 1 and 20),
  display_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (restaurant_id, id),
  unique (restaurant_id, code)
);

create table if not exists public.fo_rooms (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  room_type_id uuid not null,
  room_number text not null,
  floor_label text,
  housekeeping_status text not null default 'clean' check (housekeeping_status in ('clean', 'dirty')),
  out_of_service boolean not null default false,
  oos_reason text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (restaurant_id, id),
  unique (restaurant_id, branch_id, room_number),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, room_type_id) references public.fo_room_types(restaurant_id, id),
  constraint fo_rooms_oos_reason_check check (out_of_service = false or coalesce(btrim(oos_reason), '') <> '')
);
create index if not exists fo_rooms_branch_idx on public.fo_rooms (branch_id) where active;

create table if not exists public.fo_guests (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  full_name text not null,
  phone text,
  email text,
  id_type text check (id_type is null or id_type in ('passport', 'aadhaar', 'driving_licence', 'voter_id', 'other')),
  id_number text,
  address text,
  city text,
  country text,
  notes text,
  customer_id uuid,
  created_at timestamptz not null default now(),
  created_by uuid,
  unique (restaurant_id, id),
  foreign key (restaurant_id, customer_id) references public.customers(restaurant_id, id)
);
create index if not exists fo_guests_phone_idx on public.fo_guests (restaurant_id, phone) where phone is not null;
create index if not exists fo_guests_name_idx on public.fo_guests (restaurant_id, lower(full_name));

-- One stay = one reservation = one folio. room_id is null until check-in.
create table if not exists public.fo_stays (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  stay_no int not null,
  guest_id uuid not null,
  room_type_id uuid not null,
  room_id uuid,
  arrival date not null,
  departure date not null,
  adults int not null default 1 check (adults between 1 and 20),
  children int not null default 0 check (children between 0 and 20),
  nightly_rate numeric(12,2) not null check (nightly_rate >= 0),
  status text not null default 'reserved'
    check (status in ('reserved', 'inhouse', 'checked_out', 'cancelled', 'no_show')),
  source text not null default 'walk_in' check (source in ('walk_in', 'phone', 'email', 'ota', 'corporate', 'other')),
  notes text,
  booked_on date not null,
  checked_in_at timestamptz,
  checked_out_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  client_ref uuid,
  unique (restaurant_id, id),
  unique (restaurant_id, stay_no),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, guest_id) references public.fo_guests(restaurant_id, id),
  foreign key (restaurant_id, room_type_id) references public.fo_room_types(restaurant_id, id),
  foreign key (restaurant_id, room_id) references public.fo_rooms(restaurant_id, id),
  constraint fo_stays_dates_check check (departure > arrival),
  constraint fo_stays_inhouse_has_room check (status <> 'inhouse' or room_id is not null)
);
create unique index if not exists fo_stays_client_ref_uq on public.fo_stays (restaurant_id, client_ref) where client_ref is not null;
create index if not exists fo_stays_branch_status_idx on public.fo_stays (branch_id, status);
create index if not exists fo_stays_arrival_idx on public.fo_stays (branch_id, arrival);
create index if not exists fo_stays_room_idx on public.fo_stays (room_id) where status = 'inhouse';

-- Per-restaurant stay numbering. Locked row, not max()+1, so two receptions cannot take the same number.
create table if not exists public.fo_counters (
  restaurant_id uuid primary key references public.restaurants(id) on delete cascade,
  last_stay_no int not null default 0
);

create table if not exists public.fo_charges (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  stay_id uuid not null,
  business_date date not null,
  kind text not null check (kind in ('room', 'food', 'laundry', 'telephone', 'minibar', 'misc')),
  description text not null,
  quantity numeric(10,3) not null default 1 check (quantity > 0),
  unit_amount numeric(12,2) not null check (unit_amount >= 0),
  net_amount numeric(12,2) not null check (net_amount >= 0),
  tax_pct numeric(5,2) not null default 0 check (tax_pct >= 0 and tax_pct <= 100),
  tax_amount numeric(12,2) not null default 0 check (tax_amount >= 0),
  total_amount numeric(12,2) not null check (total_amount >= 0),
  order_id uuid,
  voided_at timestamptz,
  void_reason text,
  voided_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  client_ref uuid,
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, stay_id) references public.fo_stays(restaurant_id, id) on delete cascade,
  constraint fo_charges_void_reason_check check (voided_at is null or coalesce(btrim(void_reason), '') <> '')
);
create unique index if not exists fo_charges_client_ref_uq on public.fo_charges (restaurant_id, client_ref) where client_ref is not null;
create index if not exists fo_charges_stay_idx on public.fo_charges (stay_id) where voided_at is null;
create index if not exists fo_charges_date_idx on public.fo_charges (branch_id, business_date);
-- One room charge per stay per night, and the night audit relies on it to stay idempotent.
create unique index if not exists fo_charges_room_night_uq
  on public.fo_charges (stay_id, business_date) where kind = 'room' and voided_at is null;

create table if not exists public.fo_payments (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  stay_id uuid not null,
  business_date date not null,
  amount numeric(12,2) not null check (amount > 0),
  payment_method_id uuid,
  method_name text not null,
  is_refund boolean not null default false,
  reference text,
  voided_at timestamptz,
  void_reason text,
  voided_by uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  client_ref uuid,
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, stay_id) references public.fo_stays(restaurant_id, id) on delete cascade,
  constraint fo_payments_void_reason_check check (voided_at is null or coalesce(btrim(void_reason), '') <> '')
);
create unique index if not exists fo_payments_client_ref_uq on public.fo_payments (restaurant_id, client_ref) where client_ref is not null;
create index if not exists fo_payments_stay_idx on public.fo_payments (stay_id) where voided_at is null;
create index if not exists fo_payments_date_idx on public.fo_payments (branch_id, business_date);

create table if not exists public.fo_night_audits (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  business_date date not null,
  rooms_available int not null default 0,
  rooms_sold int not null default 0,
  occupancy_pct numeric(6,2) not null default 0,
  room_revenue numeric(14,2) not null default 0,
  other_revenue numeric(14,2) not null default 0,
  collections numeric(14,2) not null default 0,
  adr numeric(12,2) not null default 0,
  revpar numeric(12,2) not null default 0,
  no_shows int not null default 0,
  charges_posted int not null default 0,
  run_by uuid,
  run_at timestamptz not null default now(),
  unique (restaurant_id, id),
  unique (branch_id, business_date),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id)
);

-- ---------------------------------------------------------------- 5. RLS: read only, tenant and outlet scoped
do $$
declare t text;
begin
  foreach t in array array['fo_branch_settings', 'fo_room_types', 'fo_rooms', 'fo_guests', 'fo_stays',
                           'fo_charges', 'fo_payments', 'fo_night_audits', 'fo_counters'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from authenticated, anon', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
  end loop;
end $$;

-- Restaurant-wide (a group shares guests and room types across properties).
create policy tenant_read on public.fo_room_types for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
create policy tenant_read on public.fo_guests for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));

-- Outlet scoped (rooms, stays and money belong to one property).
create policy tenant_read on public.fo_branch_settings for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
create policy tenant_read on public.fo_rooms for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))
       or (select app.has_permission('fo.housekeeping'))));
create policy tenant_read on public.fo_stays for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
create policy tenant_read on public.fo_charges for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
create policy tenant_read on public.fo_payments for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
create policy tenant_read on public.fo_night_audits for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
-- fo_counters: no read policy. It is bookkeeping, not business data.

-- ---------------------------------------------------------------- 6. tax
-- Room tax follows the tariff slab; everything else uses one rate. Both live in fo_branch_settings.
create or replace function app.fo_room_tax_pct(p_branch uuid, p_rate numeric) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce(p_rate, 0) > coalesce(s.room_tax_threshold, 7500)
              then coalesce(s.room_tax_pct_high, 18) else coalesce(s.room_tax_pct, 5) end
    from public.branches b left join public.fo_branch_settings s on s.branch_id = b.id
   where b.id = p_branch;
$$;
create or replace function app.fo_other_tax_pct(p_branch uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(s.other_tax_pct, 5) from public.branches b
    left join public.fo_branch_settings s on s.branch_id = b.id where b.id = p_branch;
$$;
revoke all on function app.fo_room_tax_pct(uuid, numeric), app.fo_other_tax_pct(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------- 7. reads
-- Rooms free for every night of [arrival, departure), by room type. A room already held by a reserved or in-house
-- stay that overlaps the range is not free; out-of-service and inactive rooms never count.
create or replace function public.fo_availability(p_arrival date, p_departure date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_out jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  if p_arrival is null or p_departure is null or p_departure <= p_arrival then
    raise exception 'Give an arrival date and a later departure date.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'room_type_id', t.id, 'code', t.code, 'name', t.name, 'base_rate', t.base_rate,
           'max_occupancy', t.max_occupancy, 'rooms', t.total, 'free', t.free) order by t.display_order, t.name), '[]'::jsonb)
    into v_out
    from (select rt.id, rt.code, rt.name, rt.base_rate, rt.max_occupancy, rt.display_order,
                 count(r.id) as total,
                 count(r.id) filter (where not exists (
                   select 1 from public.fo_stays s
                    where s.room_id = r.id and s.status in ('reserved', 'inhouse')
                      and s.arrival < p_departure and s.departure > p_arrival)) as free
            from public.fo_room_types rt
            left join public.fo_rooms r on r.restaurant_id = rt.restaurant_id and r.room_type_id = rt.id
                 and r.branch_id = v_branch and r.active and not r.out_of_service
           where rt.restaurant_id = v_rest and rt.active
           group by rt.id, rt.code, rt.name, rt.base_rate, rt.max_occupancy, rt.display_order) t;
  return v_out;
end $$;

-- The room board: every room with its housekeeping state and who is in it.
create or replace function public.fo_room_board() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_out jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage', 'fo.housekeeping']);
  select coalesce(jsonb_agg(jsonb_build_object(
           'room_id', r.id, 'room_number', r.room_number, 'floor', r.floor_label,
           'room_type', rt.name, 'room_type_id', rt.id,
           'housekeeping', r.housekeeping_status, 'out_of_service', r.out_of_service, 'oos_reason', r.oos_reason,
           'occupied', s.id is not null, 'stay_id', s.id, 'stay_no', s.stay_no,
           'guest_name', g.full_name, 'departure', s.departure)
           order by r.floor_label nulls first, r.room_number), '[]'::jsonb)
    into v_out
    from public.fo_rooms r
    join public.fo_room_types rt on rt.restaurant_id = r.restaurant_id and rt.id = r.room_type_id
    left join public.fo_stays s on s.room_id = r.id and s.status = 'inhouse'
    left join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
   where r.restaurant_id = v_rest and r.branch_id = v_branch and r.active;
  return v_out;
end $$;

-- One guest folio: the stay, its charges, its payments and the balance.
create or replace function public.fo_folio(p_stay uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        s public.fo_stays; v_charges jsonb; v_payments jsonb; v_charged numeric; v_paid numeric; v_refunded numeric;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'charge_id', c.id, 'on', c.business_date, 'kind', c.kind, 'description', c.description,
           'quantity', c.quantity, 'unit_amount', c.unit_amount, 'net_amount', c.net_amount,
           'tax_pct', c.tax_pct, 'tax_amount', c.tax_amount, 'total', c.total_amount,
           'order_id', c.order_id, 'voided', c.voided_at is not null, 'void_reason', c.void_reason)
           order by c.business_date, c.created_at), '[]'::jsonb),
         coalesce(sum(c.total_amount) filter (where c.voided_at is null), 0)
    into v_charges, v_charged
    from public.fo_charges c where c.stay_id = s.id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'payment_id', p.id, 'on', p.business_date, 'amount', p.amount, 'method', p.method_name,
           'is_refund', p.is_refund, 'reference', p.reference,
           'voided', p.voided_at is not null, 'void_reason', p.void_reason)
           order by p.business_date, p.created_at), '[]'::jsonb),
         coalesce(sum(p.amount) filter (where p.voided_at is null and not p.is_refund), 0),
         coalesce(sum(p.amount) filter (where p.voided_at is null and p.is_refund), 0)
    into v_payments, v_paid, v_refunded
    from public.fo_payments p where p.stay_id = s.id;

  return jsonb_build_object(
    'stay', jsonb_build_object(
      'stay_id', s.id, 'stay_no', s.stay_no, 'status', s.status, 'arrival', s.arrival, 'departure', s.departure,
      'nights', (s.departure - s.arrival), 'adults', s.adults, 'children', s.children,
      'nightly_rate', s.nightly_rate, 'source', s.source, 'notes', s.notes,
      'room_id', s.room_id,
      'room_number', (select r.room_number from public.fo_rooms r where r.id = s.room_id),
      'room_type', (select rt.name from public.fo_room_types rt where rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id),
      'guest', (select jsonb_build_object('guest_id', g.id, 'full_name', g.full_name, 'phone', g.phone, 'email', g.email)
                  from public.fo_guests g where g.restaurant_id = s.restaurant_id and g.id = s.guest_id)),
    'charges', v_charges, 'payments', v_payments,
    'totals', jsonb_build_object('charged', v_charged, 'paid', v_paid, 'refunded', v_refunded,
                                 'balance', v_charged - v_paid + v_refunded));
end $$;

revoke all on function public.fo_availability(date, date), public.fo_room_board(), public.fo_folio(uuid) from public, anon;
grant execute on function public.fo_availability(date, date), public.fo_room_board(), public.fo_folio(uuid) to authenticated, service_role;
