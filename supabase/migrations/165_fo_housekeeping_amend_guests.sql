-- 165: Front Office batch A (SNA Hospitality). Depends on 160-164. Additive: new columns, new functions; three
-- existing Front Office functions (fo_availability, fo_create_stay, fo_set_room_status) are replaced with the same
-- signature (fo_availability and fo_create_stay now count room types, which fixes overbooking). Nothing outside Front Office is touched. Safe to run again.
--
--   * Housekeeping: who cleans a room, a supervisor "inspected" step, a daily list (OPERA / Winsar housekeeping).
--   * Amend a stay: extend, shorten, change the rate for the nights still to come (Winsar "Amend stay", OPERA "Edit reservation").
--   * Move a charge to another guest's folio (OPERA "Transfer", Winsar "Folio transfer").
--   * Guest profile: VIP, preferences, blocked guest, search with stay history (OPERA profiles).
--   * Stay chart: rooms against dates (OPERA "Room Plan", Winsar "Room position").

alter table public.fo_rooms
  add column if not exists hk_inspected boolean not null default false,
  add column if not exists hk_attendant uuid,
  add column if not exists hk_note text;
alter table public.fo_guests
  add column if not exists vip boolean not null default false,
  add column if not exists preferences text,
  add column if not exists blocked boolean not null default false,
  add column if not exists blocked_reason text;
alter table public.fo_guests drop constraint if exists fo_guests_blocked_reason_check;
alter table public.fo_guests add constraint fo_guests_blocked_reason_check
  check (blocked = false or coalesce(btrim(blocked_reason), '') <> '');

-- ------------------------------------------------------------ availability by room type (overbooking fix)
-- A reservation is for a room TYPE; the room is chosen at check-in. Counting only stays that already hold a room let
-- two Deluxe rooms take three bookings. A type has room for one more when, on every night asked for, the stays of
-- that type already booked or in the house are fewer than its usable rooms.
create or replace function app.fo_type_free(p_branch uuid, p_type uuid, p_arrival date, p_departure date,
                                            p_except uuid default null) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(
    (select count(*) from public.fo_rooms r
      where r.branch_id = p_branch and r.room_type_id = p_type and r.active and not r.out_of_service)
    - coalesce((select max(n) from (
        select count(*) as n
          from generate_series(p_arrival, p_departure - 1, interval '1 day') d
          join public.fo_stays s on s.branch_id = p_branch and s.room_type_id = p_type
           and s.status in ('reserved', 'inhouse') and (p_except is null or s.id <> p_except)
           and s.arrival <= d::date and s.departure > d::date
         group by d) x), 0), 0)::int;
$$;
revoke all on function app.fo_type_free(uuid, uuid, date, date, uuid) from public, anon, authenticated;

create or replace function public.fo_availability(p_arrival date, p_departure date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_out jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  if p_arrival is null or p_departure is null or p_departure <= p_arrival then
    raise exception 'Give an arrival date and a later departure date.';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'room_type_id', rt.id, 'code', rt.code, 'name', rt.name, 'base_rate', rt.base_rate,
           'max_occupancy', rt.max_occupancy,
           'rooms', (select count(*) from public.fo_rooms r where r.branch_id = v_branch and r.room_type_id = rt.id
                      and r.active and not r.out_of_service),
           'free', app.fo_type_free(v_branch, rt.id, p_arrival, p_departure)) order by rt.display_order, rt.name), '[]'::jsonb)
    into v_out
    from public.fo_room_types rt where rt.restaurant_id = v_rest and rt.active;
  return v_out;
end $$;
grant execute on function public.fo_availability(date, date) to authenticated, service_role;

-- ------------------------------------------------------------ housekeeping
-- Room status changes. Same rules as before; a room that turns dirty loses its inspected mark, a room set clean
-- starts un-inspected, and 'inspected' means clean AND signed off.
create or replace function public.fo_set_room_status(
  p_room uuid, p_housekeeping text default null,
  p_out_of_service boolean default null, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        r public.fo_rooms; v_hk text; v_oos boolean; v_insp boolean;
begin
  v_user := app.require_fo(array['fo.housekeeping', 'fo.manage']);
  select * into r from public.fo_rooms where id = p_room and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That room was not found.'; end if;

  v_hk := coalesce(p_housekeeping, r.housekeeping_status);
  if v_hk = 'inspected' then v_hk := 'clean'; v_insp := true;
  elsif v_hk in ('clean', 'dirty') then v_insp := case when v_hk = r.housekeeping_status then r.hk_inspected else false end;
  else raise exception 'A room is clean, dirty or inspected.'; end if;
  v_oos := coalesce(p_out_of_service, r.out_of_service);

  if v_oos and coalesce(btrim(coalesce(p_reason, r.oos_reason, '')), '') = '' then
    raise exception 'Give a reason for taking room % out of service.', r.room_number; end if;
  if v_oos and exists (select 1 from public.fo_stays s where s.room_id = r.id and s.status = 'inhouse') then
    raise exception 'Room % has a guest in it.', r.room_number; end if;

  update public.fo_rooms set
    housekeeping_status = v_hk, hk_inspected = v_insp, out_of_service = v_oos,
    oos_reason = case when v_oos then coalesce(nullif(btrim(coalesce(p_reason, '')), ''), r.oos_reason) else null end
   where id = r.id;

  perform app.audit('fo_room_status', 'fo_room', r.id, jsonb_build_object(
    'room_number', r.room_number, 'housekeeping', v_hk, 'inspected', v_insp, 'out_of_service', v_oos),
    jsonb_build_object('housekeeping', r.housekeeping_status, 'out_of_service', r.out_of_service));
  return jsonb_build_object('room_id', r.id, 'housekeeping', v_hk, 'inspected', v_insp, 'out_of_service', v_oos);
end $$;

-- Hand rooms to an attendant (p_attendant null clears). Staff of this hotel only.
create or replace function public.fo_hk_assign(p_rooms uuid[], p_attendant uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_n int;
begin
  perform app.require_fo(array['fo.housekeeping', 'fo.manage']);
  if p_attendant is not null and not exists (
       select 1 from public.users where id = p_attendant and restaurant_id = v_rest and is_active) then
    raise exception 'That staff member was not found.'; end if;
  update public.fo_rooms set hk_attendant = p_attendant,
         hk_note = case when p_note is null then hk_note else nullif(btrim(p_note), '') end
   where restaurant_id = v_rest and branch_id = v_branch and id = any(p_rooms);
  get diagnostics v_n = row_count;
  perform app.audit('fo_hk_assigned', 'fo_room', null, jsonb_build_object('rooms', v_n, 'attendant', p_attendant));
  return jsonb_build_object('rooms', v_n);
end $$;

-- The housekeeping list for today: every active room with what it needs.
--   task: 'departure' (guest leaves today), 'stayover' (guest stays), 'vacant_dirty', 'arrival_ready' (arrival today and
--   not yet clean), 'ready' (clean and nothing to do), 'out_of_service'.
create or replace function public.fo_hk_list() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_today date; v_out jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage', 'fo.housekeeping']);
  v_today := app.business_today(v_branch);
  select coalesce(jsonb_agg(x order by (x->>'room_number')), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'room_id', r.id, 'room_number', r.room_number, 'floor', r.floor_label, 'room_type', rt.name,
      'housekeeping', r.housekeeping_status, 'inspected', r.hk_inspected and r.housekeeping_status = 'clean',
      'out_of_service', r.out_of_service, 'oos_reason', r.oos_reason, 'note', r.hk_note,
      'attendant_id', r.hk_attendant, 'attendant', u.full_name,
      'occupied', s.id is not null, 'guest_name', g.full_name, 'vip', coalesce(g.vip, false),
      'departure', s.departure,
      'arriving_today', exists (select 1 from public.fo_stays a
                                 where a.room_id = r.id and a.status = 'reserved' and a.arrival = v_today),
      'task', case
        when r.out_of_service then 'out_of_service'
        when s.id is not null and s.departure <= v_today then 'departure'
        when s.id is not null then 'stayover'
        when r.housekeeping_status = 'dirty' then 'vacant_dirty'
        when not r.hk_inspected then 'to_inspect'
        else 'ready' end) as x
      from public.fo_rooms r
      join public.fo_room_types rt on rt.restaurant_id = r.restaurant_id and rt.id = r.room_type_id
      left join public.fo_stays s on s.room_id = r.id and s.status = 'inhouse'
      left join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
      left join public.users u on u.id = r.hk_attendant
     where r.restaurant_id = v_rest and r.branch_id = v_branch and r.active) q;
  return v_out;
end $$;

-- ------------------------------------------------------------ amend a stay
-- Extend, shorten and/or change the nightly rate. A rate change affects nights not yet charged (the night audit
-- reads nightly_rate when it posts); nights already on the folio stay as they were. Every change needs a reason.
create or replace function public.fo_amend_stay(
  p_stay uuid, p_departure date default null, p_nightly_rate numeric default null,
  p_reason text default null, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; v_today date; v_dep date; v_rate numeric; v_last_charged date;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for the change.'; end if;
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status not in ('reserved', 'inhouse') then
    raise exception 'A % stay cannot be changed.', s.status; end if;

  v_today := app.business_today(v_branch);
  v_dep := coalesce(p_departure, s.departure);
  v_rate := coalesce(p_nightly_rate, s.nightly_rate);
  if v_rate < 0 then raise exception 'The rate cannot be negative.'; end if;
  if v_dep <= s.arrival then raise exception 'Departure must be after arrival (%).', s.arrival; end if;

  if v_dep <> s.departure then
    if s.status = 'inhouse' and v_dep < v_today then
      raise exception 'A guest in the house cannot be made to leave before today (%).', v_today; end if;
    select max(business_date) into v_last_charged from public.fo_charges
     where stay_id = s.id and kind = 'room' and voided_at is null;
    if v_last_charged is not null and v_dep <= v_last_charged then
      raise exception 'Room charges are already posted up to %. Void them first, or leave on %.',
        v_last_charged, v_last_charged + 1; end if;
    if v_dep > s.departure and s.room_id is not null
       and not app.fo_room_free(s.room_id, s.arrival, v_dep, s.id) then
      raise exception 'The room is taken after %, so the stay cannot be extended in it. Change room instead.', s.departure;
    end if;
    if v_dep > s.departure and app.fo_type_free(v_branch, s.room_type_id, s.arrival, v_dep, s.id) = 0 then
      raise exception 'No room of that type is free for the extra nights.'; end if;
  end if;

  update public.fo_stays set departure = v_dep, nightly_rate = v_rate,
         notes = case when p_notes is null then notes else nullif(btrim(p_notes), '') end
   where id = s.id;
  perform app.audit('fo_stay_amended', 'fo_stay', s.id,
    jsonb_build_object('departure', v_dep, 'rate', v_rate, 'reason', btrim(p_reason)),
    jsonb_build_object('departure', s.departure, 'rate', s.nightly_rate));
  return jsonb_build_object('stay_id', s.id, 'departure', v_dep, 'nightly_rate', v_rate, 'nights', v_dep - s.arrival);
end $$;

-- ------------------------------------------------------------ move a charge to another folio
create or replace function public.fo_move_charge(p_charge uuid, p_to_stay uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        c public.fo_charges; t public.fo_stays; f public.fo_stays;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for the transfer.'; end if;
  select * into c from public.fo_charges where id = p_charge and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That charge was not found.'; end if;
  if c.voided_at is not null then raise exception 'That charge is already voided.'; end if;
  if c.kind = 'room' then raise exception 'A room charge belongs to its own stay and cannot be moved.'; end if;
  select * into f from public.fo_stays where id = c.stay_id for update;
  select * into t from public.fo_stays where id = p_to_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'The other folio was not found.'; end if;
  if t.id = f.id then raise exception 'That charge is already on this folio.'; end if;
  if f.status not in ('reserved', 'inhouse') then raise exception 'This folio is closed.'; end if;
  if t.status not in ('reserved', 'inhouse') then raise exception 'The other folio is % and cannot take charges.', t.status; end if;

  update public.fo_charges set stay_id = t.id where id = c.id;
  perform app.audit('fo_charge_moved', 'fo_charge', c.id,
    jsonb_build_object('to_stay', t.id, 'reason', btrim(p_reason), 'total', c.total_amount),
    jsonb_build_object('from_stay', f.id));
  return jsonb_build_object('charge_id', c.id, 'from_stay', f.id, 'to_stay', t.id);
end $$;

-- ------------------------------------------------------------ guest profile
create or replace function public.fo_set_guest_flags(
  p_guest uuid, p_vip boolean default null, p_preferences text default null,
  p_blocked boolean default null, p_blocked_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); g public.fo_guests; v_blocked boolean;
begin
  perform app.require_fo(array['fo.manage']);
  select * into g from public.fo_guests where id = p_guest and restaurant_id = v_rest for update;
  if not found then raise exception 'That guest was not found.'; end if;
  v_blocked := coalesce(p_blocked, g.blocked);
  if v_blocked and coalesce(btrim(coalesce(p_blocked_reason, g.blocked_reason, '')), '') = '' then
    raise exception 'Give a reason for blocking this guest.'; end if;
  update public.fo_guests set
    vip = coalesce(p_vip, vip),
    preferences = case when p_preferences is null then preferences else nullif(btrim(p_preferences), '') end,
    blocked = v_blocked,
    blocked_reason = case when v_blocked then coalesce(nullif(btrim(coalesce(p_blocked_reason, '')), ''), blocked_reason) else null end
   where id = g.id;
  perform app.audit('fo_guest_flags', 'fo_guest', g.id,
    jsonb_build_object('vip', coalesce(p_vip, g.vip), 'blocked', v_blocked));
  return jsonb_build_object('guest_id', g.id, 'vip', coalesce(p_vip, g.vip), 'blocked', v_blocked);
end $$;

-- Search by name, phone or email. Returns the profile and a short stay history.
create or replace function public.fo_find_guests(p_query text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_q text := btrim(coalesce(p_query, '')); v_out jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  if length(v_q) < 2 then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'guest_id', g.id, 'full_name', g.full_name, 'phone', g.phone, 'email', g.email, 'city', g.city,
      'vip', g.vip, 'blocked', g.blocked, 'blocked_reason', g.blocked_reason, 'preferences', g.preferences,
      'stays', (select count(*) from public.fo_stays s where s.guest_id = g.id and s.status in ('inhouse', 'checked_out')),
      'last_stay', (select max(s.arrival) from public.fo_stays s where s.guest_id = g.id and s.status in ('inhouse', 'checked_out')))
      order by g.full_name), '[]'::jsonb) into v_out
    from (select * from public.fo_guests
           where restaurant_id = v_rest
             and (full_name ilike '%' || v_q || '%' or phone like '%' || v_q || '%' or email ilike '%' || v_q || '%')
           order by full_name limit 25) g;
  return v_out;
end $$;

-- A blocked guest cannot be booked. Same signature as before; the only addition is the check after the repeat test.
create or replace function public.fo_create_stay(
  p_guest_id uuid, p_room_type_id uuid, p_arrival date, p_departure date,
  p_nightly_rate numeric default null, p_adults int default 1, p_children int default 0,
  p_source text default 'walk_in', p_notes text default null, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        v_today date; v_rate numeric; v_type public.fo_room_types; v_stay uuid; v_no int; v_free int;
        v_blocked boolean; v_why text;
begin
  v_user := app.require_fo(array['fo.manage']);

  if p_client_ref is not null then
    select id into v_stay from public.fo_stays where restaurant_id = v_rest and client_ref = p_client_ref;
    if v_stay is not null then
      return jsonb_build_object('stay_id', v_stay, 'repeat', true,
             'stay_no', (select stay_no from public.fo_stays where id = v_stay));
    end if;
  end if;

  select blocked, blocked_reason into v_blocked, v_why from public.fo_guests where id = p_guest_id and restaurant_id = v_rest;
  if coalesce(v_blocked, false) then raise exception 'This guest is blocked: %', v_why; end if;

  v_today := app.business_today(v_branch);
  if p_arrival is null or p_departure is null or p_departure <= p_arrival then
    raise exception 'Give an arrival date and a later departure date.';
  end if;
  if p_arrival < v_today then
    raise exception 'Arrival cannot be before the business date (%).', v_today;
  end if;

  select * into v_type from public.fo_room_types where id = p_room_type_id and restaurant_id = v_rest and active;
  if not found then raise exception 'That room type was not found.'; end if;
  if coalesce(p_adults, 1) + coalesce(p_children, 0) > v_type.max_occupancy then
    raise exception '% holds % people; you asked for %.', v_type.name, v_type.max_occupancy,
      coalesce(p_adults, 1) + coalesce(p_children, 0);
  end if;

  v_rate := coalesce(p_nightly_rate, v_type.base_rate);
  if v_rate < 0 then raise exception 'The rate cannot be negative.'; end if;

  v_free := app.fo_type_free(v_branch, p_room_type_id, p_arrival, p_departure);
  if v_free = 0 then
    raise exception 'No % is free from % to %.', v_type.name, p_arrival, p_departure;
  end if;

  v_no := app.fo_next_stay_no(v_rest);
  insert into public.fo_stays (restaurant_id, branch_id, stay_no, guest_id, room_type_id, arrival, departure,
                               adults, children, nightly_rate, status, source, notes, booked_on, created_by, client_ref)
  values (v_rest, v_branch, v_no, p_guest_id, p_room_type_id, p_arrival, p_departure,
          coalesce(p_adults, 1), coalesce(p_children, 0), v_rate, 'reserved',
          coalesce(p_source, 'walk_in'), p_notes, v_today, v_user, p_client_ref)
  returning id into v_stay;

  perform app.audit('fo_stay_created', 'fo_stay', v_stay, jsonb_build_object(
    'stay_no', v_no, 'guest_id', p_guest_id, 'arrival', p_arrival, 'departure', p_departure, 'rate', v_rate));
  return jsonb_build_object('stay_id', v_stay, 'stay_no', v_no, 'nightly_rate', v_rate, 'repeat', false);
end $$;

-- ------------------------------------------------------------ stay chart
-- Rooms (rows) against p_days dates from p_from. Each cell-run is a stay: reserved, in-house or checked out.
create or replace function public.fo_chart(p_from date default null, p_days int default 14) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        v_from date; v_days int; v_to date;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  v_from := coalesce(p_from, app.business_today(v_branch));
  v_days := least(greatest(coalesce(p_days, 14), 1), 62);
  v_to := v_from + v_days;
  return jsonb_build_object('from', v_from, 'days', v_days,
    'rooms', coalesce((select jsonb_agg(jsonb_build_object(
        'room_id', r.id, 'room_number', r.room_number, 'room_type', rt.name, 'out_of_service', r.out_of_service,
        'stays', coalesce((select jsonb_agg(jsonb_build_object(
            'stay_id', s.id, 'stay_no', s.stay_no, 'guest_name', g.full_name, 'vip', g.vip, 'status', s.status,
            'arrival', s.arrival, 'departure', s.departure) order by s.arrival)
          from public.fo_stays s join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
         where s.room_id = r.id and s.status in ('reserved', 'inhouse', 'checked_out')
           and s.arrival < v_to and s.departure > v_from), '[]'::jsonb))
        order by r.room_number)
      from public.fo_rooms r join public.fo_room_types rt on rt.restaurant_id = r.restaurant_id and rt.id = r.room_type_id
     where r.restaurant_id = v_rest and r.branch_id = v_branch and r.active), '[]'::jsonb),
    -- Reservations with no room yet (assigned at check-in): shown as a count per day by the screen.
    'unassigned', coalesce((select jsonb_agg(jsonb_build_object(
        'stay_id', s.id, 'stay_no', s.stay_no, 'guest_name', g.full_name, 'room_type', rt.name,
        'arrival', s.arrival, 'departure', s.departure) order by s.arrival, s.stay_no)
      from public.fo_stays s
      join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
      join public.fo_room_types rt on rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id
     where s.restaurant_id = v_rest and s.branch_id = v_branch and s.status = 'reserved' and s.room_id is null
       and s.arrival < v_to and s.departure > v_from), '[]'::jsonb));
end $$;

revoke all on function
  public.fo_hk_assign(uuid[], uuid, text), public.fo_hk_list(),
  public.fo_amend_stay(uuid, date, numeric, text, text), public.fo_move_charge(uuid, uuid, text),
  public.fo_set_guest_flags(uuid, boolean, text, boolean, text), public.fo_find_guests(text),
  public.fo_chart(date, int) from public, anon;
grant execute on function
  public.fo_hk_assign(uuid[], uuid, text), public.fo_hk_list(),
  public.fo_amend_stay(uuid, date, numeric, text, text), public.fo_move_charge(uuid, uuid, text),
  public.fo_set_guest_flags(uuid, boolean, text, boolean, text), public.fo_find_guests(text),
  public.fo_chart(date, int) to authenticated, service_role;
