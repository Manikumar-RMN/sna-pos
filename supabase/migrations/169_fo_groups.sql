-- 169: Front Office group bookings (SNA Hospitality, batch C part 1). Depends on 160-168. Additive: one new table, one new
-- column on fo_stays, new functions. Nothing existing is replaced. Safe to run again.
--
-- A group is a named block of rooms for one arrival and one departure (a wedding party, a tour, a company event).
--   * Booking a group creates one ordinary stay per room, all or nothing: if one room type runs out, nothing is booked.
--   * Every stay goes through the same checks and the same rate-plan pricing as a single booking (fo_create_stay is reused).
--   * All stays start under the contact person. Real guest names are put on each room later (fo_set_stay_guest) before
--     check-in. Each room keeps its own folio and, later, its own tax invoice.
--   * One group screen shows every room, its status and balance, and the group total.
--   * Splitting a bill between a company and the guests (folio windows) is NOT in this migration.

create table if not exists public.fo_groups (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null,
  group_no int not null,
  name text not null check (btrim(name) <> ''),
  contact_guest_id uuid not null,
  arrival date not null,
  departure date not null,
  notes text,
  status text not null default 'active' check (status in ('active', 'cancelled')),
  cancel_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  client_ref uuid,
  unique (restaurant_id, id),
  unique (restaurant_id, group_no),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, contact_guest_id) references public.fo_guests(restaurant_id, id),
  constraint fo_groups_dates_check check (departure > arrival)
);
create unique index if not exists fo_groups_client_ref_uq on public.fo_groups (restaurant_id, client_ref) where client_ref is not null;
create index if not exists fo_groups_branch_idx on public.fo_groups (branch_id, arrival);

alter table public.fo_stays add column if not exists group_id uuid;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'fo_stays_group_fk') then
    alter table public.fo_stays add constraint fo_stays_group_fk
      foreign key (restaurant_id, group_id) references public.fo_groups(restaurant_id, id);
  end if;
end $$;
create index if not exists fo_stays_group_idx on public.fo_stays (group_id) where group_id is not null;

alter table public.fo_groups enable row level security;
revoke all on public.fo_groups from authenticated, anon;
grant select on public.fo_groups to authenticated;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'fo_groups' and policyname = 'tenant_read') then
    create policy tenant_read on public.fo_groups for select to authenticated using (
      restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
      and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
  end if;
end $$;

-- ---------------------------------------------------------------- book rooms into a group (internal)
-- p_rooms: [{"room_type_id": uuid, "qty": 1..50, "adults": 2, "children": 0, "rate_plan_id": uuid|null, "rate": number|null}]
create or replace function app.fo_group_book(p_group uuid, p_rooms jsonb, p_source text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare g public.fo_groups; e jsonb; v_qty int; v_total int := 0; i int; r jsonb; v_out jsonb := '[]'::jsonb;
begin
  if p_rooms is null or jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) = 0 then
    raise exception 'Add at least one room to the group.'; end if;
  select * into g from public.fo_groups where id = p_group;
  for e in select * from jsonb_array_elements(p_rooms) loop
    v_qty := coalesce((e ->> 'qty')::int, 1);
    if v_qty < 1 or v_qty > 50 then raise exception 'Each line takes between 1 and 50 rooms.'; end if;
    v_total := v_total + v_qty;
    if v_total > 100 then raise exception 'A group can book at most 100 rooms at a time.'; end if;
    for i in 1 .. v_qty loop
      r := public.fo_create_stay(
             g.contact_guest_id, (e ->> 'room_type_id')::uuid, g.arrival, g.departure,
             nullif(e ->> 'rate', '')::numeric, coalesce((e ->> 'adults')::int, 2), coalesce((e ->> 'children')::int, 0),
             coalesce(p_source, 'corporate'), g.name, null, nullif(e ->> 'rate_plan_id', '')::uuid);
      update public.fo_stays set group_id = g.id where id = (r ->> 'stay_id')::uuid;
      v_out := v_out || jsonb_build_object('stay_id', r ->> 'stay_id', 'stay_no', (r ->> 'stay_no')::int);
    end loop;
  end loop;
  return v_out;
end $$;
revoke all on function app.fo_group_book(uuid, jsonb, text) from public, anon, authenticated;

-- ---------------------------------------------------------------- create a group
create or replace function public.fo_create_group(
  p_name text, p_contact_guest uuid, p_arrival date, p_departure date, p_rooms jsonb,
  p_notes text default null, p_source text default 'corporate', p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        g public.fo_groups; v_no int; v_stays jsonb;
begin
  v_user := app.require_fo(array['fo.manage']);
  if p_client_ref is not null then
    select * into g from public.fo_groups where restaurant_id = v_rest and client_ref = p_client_ref;
    if found then return jsonb_build_object('group_id', g.id, 'group_no', g.group_no, 'repeat', true); end if;
  end if;
  if coalesce(btrim(coalesce(p_name, '')), '') = '' then raise exception 'Give the group a name.'; end if;
  if not exists (select 1 from public.fo_guests where id = p_contact_guest and restaurant_id = v_rest) then
    raise exception 'Choose the contact person for the group.'; end if;
  if p_arrival is null or p_departure is null or p_departure <= p_arrival then
    raise exception 'Give an arrival date and a later departure date.'; end if;

  perform pg_advisory_xact_lock(hashtext('fo_group:' || v_rest::text));
  select coalesce(max(group_no), 0) + 1 into v_no from public.fo_groups where restaurant_id = v_rest;
  insert into public.fo_groups (restaurant_id, branch_id, group_no, name, contact_guest_id, arrival, departure, notes, created_by, client_ref)
  values (v_rest, v_branch, v_no, btrim(p_name), p_contact_guest, p_arrival, p_departure, nullif(btrim(coalesce(p_notes, '')), ''), v_user, p_client_ref)
  returning * into g;

  v_stays := app.fo_group_book(g.id, p_rooms, p_source);

  perform app.audit('fo_group_created', 'fo_group', g.id, jsonb_build_object(
    'group_no', v_no, 'name', g.name, 'arrival', p_arrival, 'departure', p_departure, 'rooms', jsonb_array_length(v_stays)));
  return jsonb_build_object('group_id', g.id, 'group_no', v_no, 'stays', v_stays, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- add more rooms to an existing group
create or replace function public.fo_group_add_rooms(p_group uuid, p_rooms jsonb, p_source text default 'corporate') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); g public.fo_groups; v_stays jsonb;
begin
  perform app.require_fo(array['fo.manage']);
  select * into g from public.fo_groups where id = p_group and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That group was not found.'; end if;
  if g.status = 'cancelled' then raise exception 'This group has been cancelled.'; end if;
  v_stays := app.fo_group_book(g.id, p_rooms, p_source);
  perform app.audit('fo_group_rooms_added', 'fo_group', g.id, jsonb_build_object('rooms', jsonb_array_length(v_stays)));
  return jsonb_build_object('group_id', g.id, 'stays', v_stays);
end $$;

-- ---------------------------------------------------------------- put a real guest on a reserved room
create or replace function public.fo_set_stay_guest(p_stay uuid, p_guest uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        s public.fo_stays; v_blocked boolean; v_why text;
begin
  perform app.require_fo(array['fo.manage']);
  select * into s from public.fo_stays where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status <> 'reserved' then raise exception 'The guest can be changed only before check-in; this stay is %.', s.status; end if;
  select blocked, blocked_reason into v_blocked, v_why from public.fo_guests where id = p_guest and restaurant_id = v_rest;
  if not found then raise exception 'That guest was not found.'; end if;
  if coalesce(v_blocked, false) then raise exception 'This guest is blocked: %', v_why; end if;
  update public.fo_stays set guest_id = p_guest where id = s.id;
  perform app.audit('fo_stay_guest_changed', 'fo_stay', s.id, jsonb_build_object('guest_id', p_guest), jsonb_build_object('guest_id', s.guest_id));
  return jsonb_build_object('stay_id', s.id);
end $$;

-- ---------------------------------------------------------------- read: one group
create or replace function public.fo_group_view(p_group uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); g public.fo_groups; v_stays jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  select * into g from public.fo_groups where id = p_group and restaurant_id = v_rest and branch_id = v_branch;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'stay_id', s.id, 'stay_no', s.stay_no, 'status', s.status, 'guest_id', s.guest_id, 'guest_name', gu.full_name,
           'room_type', rt.name, 'room_number', r.room_number, 'rate', s.nightly_rate, 'adults', s.adults, 'children', s.children,
           'charged', coalesce((select sum(c.total_amount) from public.fo_charges c where c.stay_id = s.id and c.voided_at is null), 0),
           'paid', coalesce((select sum(case when p.is_refund then -p.amount else p.amount end) from public.fo_payments p where p.stay_id = s.id and p.voided_at is null), 0),
           'balance', app.fo_balance(s.id)) order by s.stay_no), '[]'::jsonb)
    into v_stays
    from public.fo_stays s
    join public.fo_guests gu on gu.restaurant_id = s.restaurant_id and gu.id = s.guest_id
    join public.fo_room_types rt on rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id
    left join public.fo_rooms r on r.id = s.room_id
   where s.group_id = g.id;
  return jsonb_build_object(
    'group', jsonb_build_object('group_id', g.id, 'group_no', g.group_no, 'name', g.name, 'status', g.status,
             'arrival', g.arrival, 'departure', g.departure, 'nights', g.departure - g.arrival, 'notes', g.notes,
             'contact_guest_id', g.contact_guest_id, 'contact_name', (select full_name from public.fo_guests where id = g.contact_guest_id),
             'cancel_reason', g.cancel_reason),
    'stays', v_stays,
    'totals', jsonb_build_object(
      'rooms', (select count(*) from jsonb_array_elements(v_stays) x where x ->> 'status' <> 'cancelled'),
      'charged', (select coalesce(sum((x ->> 'charged')::numeric), 0) from jsonb_array_elements(v_stays) x),
      'paid', (select coalesce(sum((x ->> 'paid')::numeric), 0) from jsonb_array_elements(v_stays) x),
      'balance', (select coalesce(sum((x ->> 'balance')::numeric), 0) from jsonb_array_elements(v_stays) x where x ->> 'status' <> 'cancelled')));
end $$;

-- ---------------------------------------------------------------- read: group list
create or replace function public.fo_groups_list(p_include_past boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_today date;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  v_today := app.business_today(v_branch);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'group_id', g.id, 'group_no', g.group_no, 'name', g.name, 'status', g.status, 'arrival', g.arrival, 'departure', g.departure,
      'contact_name', gu.full_name,
      'rooms', (select count(*) from public.fo_stays s where s.group_id = g.id and s.status <> 'cancelled'),
      'in_house', (select count(*) from public.fo_stays s where s.group_id = g.id and s.status = 'inhouse'))
      order by g.arrival, g.group_no)
    from public.fo_groups g
    join public.fo_guests gu on gu.restaurant_id = g.restaurant_id and gu.id = g.contact_guest_id
   where g.restaurant_id = v_rest and g.branch_id = v_branch
     and (p_include_past or (g.status = 'active' and g.departure >= v_today))), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- the group a stay belongs to (for the folio screen)
create or replace function public.fo_stay_group(p_stay uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  return (select jsonb_build_object('group_id', g.id, 'group_no', g.group_no, 'name', g.name)
            from public.fo_stays s join public.fo_groups g on g.id = s.group_id
           where s.id = p_stay and s.restaurant_id = v_rest and s.branch_id = v_branch);
end $$;

-- ---------------------------------------------------------------- cancel a group
-- Cancels every reservation in the group. A room that is already in-house or has an advance on its folio stops the
-- whole call with a clear message, so nothing is half cancelled.
create or replace function public.fo_cancel_group(p_group uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); g public.fo_groups; s record; v_n int := 0;
begin
  perform app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for the cancellation.'; end if;
  select * into g from public.fo_groups where id = p_group and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That group was not found.'; end if;
  if g.status = 'cancelled' then return jsonb_build_object('group_id', g.id, 'repeat', true); end if;
  if exists (select 1 from public.fo_stays where group_id = g.id and status in ('inhouse', 'checked_out')) then
    raise exception 'Some rooms of this group have already checked in. Cancel the rooms that have not arrived one by one.'; end if;
  for s in select id from public.fo_stays where group_id = g.id and status = 'reserved' order by stay_no loop
    perform public.fo_cancel_stay(s.id, p_reason);
    v_n := v_n + 1;
  end loop;
  update public.fo_groups set status = 'cancelled', cancel_reason = btrim(p_reason) where id = g.id;
  perform app.audit('fo_group_cancelled', 'fo_group', g.id, jsonb_build_object('reason', btrim(p_reason), 'rooms', v_n));
  return jsonb_build_object('group_id', g.id, 'cancelled', v_n, 'repeat', false);
end $$;

revoke all on function
  public.fo_create_group(text, uuid, date, date, jsonb, text, text, uuid), public.fo_group_add_rooms(uuid, jsonb, text),
  public.fo_set_stay_guest(uuid, uuid), public.fo_group_view(uuid), public.fo_groups_list(boolean),
  public.fo_stay_group(uuid), public.fo_cancel_group(uuid, text) from public, anon;
grant execute on function
  public.fo_create_group(text, uuid, date, date, jsonb, text, text, uuid), public.fo_group_add_rooms(uuid, jsonb, text),
  public.fo_set_stay_guest(uuid, uuid), public.fo_group_view(uuid), public.fo_groups_list(boolean),
  public.fo_stay_group(uuid), public.fo_cancel_group(uuid, text) to authenticated, service_role;
