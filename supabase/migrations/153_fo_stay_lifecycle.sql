-- 153: Front Office stay lifecycle (SNA Hospitality). Depends on 152. Additive only.
--
-- Every write to a folio goes through one of these SECURITY DEFINER functions. The rules they enforce, and why:
--   * A reservation cannot arrive before the business date. Back-dating a stay would move revenue into a night the
--     audit has already closed.
--   * Check-in needs a room that is clean, not out of service, and free for every night of the stay.
--   * Check-out needs a zero balance. Money owed is collected first (one call can take the payment and check out);
--     a credit balance must be refunded first, because a negative folio is a refund the hotel owes, not a closed stay.
--   * A charge is never deleted, only voided, and a void needs a reason. Same rule as a POS bill.
--   * A stay with money on the folio cannot be cancelled; it is checked out or the payment is refunded first.
--   * Taking a room out of service needs a reason.
-- Every function is idempotent on p_client_ref, so a tablet that retries on a flaky connection does not double-post.
-- Safe to run again.

-- ---------------------------------------------------------------- helpers
-- Balance of a folio: live charges less live payments plus live refunds.
create or replace function app.fo_balance(p_stay uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select sum(c.total_amount) from public.fo_charges c where c.stay_id = p_stay and c.voided_at is null), 0)
       - coalesce((select sum(p.amount) from public.fo_payments p where p.stay_id = p_stay and p.voided_at is null and not p.is_refund), 0)
       + coalesce((select sum(p.amount) from public.fo_payments p where p.stay_id = p_stay and p.voided_at is null and p.is_refund), 0);
$$;

-- The next stay number for a restaurant. Locks one row, so two receptions never take the same number.
create or replace function app.fo_next_stay_no(p_restaurant uuid) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v int;
begin
  insert into public.fo_counters (restaurant_id, last_stay_no) values (p_restaurant, 0) on conflict do nothing;
  update public.fo_counters set last_stay_no = last_stay_no + 1 where restaurant_id = p_restaurant returning last_stay_no into v;
  return v;
end $$;

-- Is this room free for every night of [p_arrival, p_departure), ignoring one stay (used when changing room)?
create or replace function app.fo_room_free(p_room uuid, p_arrival date, p_departure date, p_except uuid default null) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select not exists (
    select 1 from public.fo_stays s
     where s.room_id = p_room and s.status in ('reserved', 'inhouse')
       and (p_except is null or s.id <> p_except)
       and s.arrival < p_departure and s.departure > p_arrival);
$$;
revoke all on function app.fo_balance(uuid), app.fo_next_stay_no(uuid), app.fo_room_free(uuid, date, date, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------- guests
-- Find a guest by phone, or create one. Phone is the key receptions actually have.
create or replace function public.fo_save_guest(
  p_full_name text, p_phone text default null, p_email text default null,
  p_id_type text default null, p_id_number text default null,
  p_address text default null, p_city text default null, p_country text default null,
  p_notes text default null, p_guest_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_user uuid; v_id uuid;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(p_full_name), '') = '' then raise exception 'Give the guest a name.'; end if;

  if p_guest_id is not null then
    update public.fo_guests set
      full_name = btrim(p_full_name), phone = nullif(btrim(coalesce(p_phone, '')), ''),
      email = nullif(btrim(coalesce(p_email, '')), ''), id_type = p_id_type,
      id_number = nullif(btrim(coalesce(p_id_number, '')), ''), address = p_address,
      city = p_city, country = p_country, notes = p_notes
     where id = p_guest_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'That guest was not found.'; end if;
    perform app.audit('fo_guest_updated', 'fo_guest', v_id, jsonb_build_object('full_name', btrim(p_full_name)));
    return jsonb_build_object('guest_id', v_id, 'created', false);
  end if;

  if nullif(btrim(coalesce(p_phone, '')), '') is not null then
    select id into v_id from public.fo_guests
     where restaurant_id = v_rest and phone = btrim(p_phone) order by created_at limit 1;
    if v_id is not null then return jsonb_build_object('guest_id', v_id, 'created', false); end if;
  end if;

  insert into public.fo_guests (restaurant_id, full_name, phone, email, id_type, id_number,
                               address, city, country, notes, created_by)
  values (v_rest, btrim(p_full_name), nullif(btrim(coalesce(p_phone, '')), ''),
          nullif(btrim(coalesce(p_email, '')), ''), p_id_type, nullif(btrim(coalesce(p_id_number, '')), ''),
          p_address, p_city, p_country, p_notes, v_user)
  returning id into v_id;
  perform app.audit('fo_guest_created', 'fo_guest', v_id, jsonb_build_object('full_name', btrim(p_full_name)));
  return jsonb_build_object('guest_id', v_id, 'created', true);
end $$;

-- ---------------------------------------------------------------- create a stay
-- A reservation (p_room_id null) or a walk-in (p_room_id given, checked in by fo_check_in afterwards).
create or replace function public.fo_create_stay(
  p_guest_id uuid, p_room_type_id uuid, p_arrival date, p_departure date,
  p_nightly_rate numeric default null, p_adults int default 1, p_children int default 0,
  p_source text default 'walk_in', p_notes text default null, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        v_today date; v_rate numeric; v_type public.fo_room_types; v_stay uuid; v_no int; v_free int;
begin
  v_user := app.require_fo(array['fo.manage']);

  if p_client_ref is not null then
    select id into v_stay from public.fo_stays where restaurant_id = v_rest and client_ref = p_client_ref;
    if v_stay is not null then
      return jsonb_build_object('stay_id', v_stay, 'repeat', true,
             'stay_no', (select stay_no from public.fo_stays where id = v_stay));
    end if;
  end if;

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

  -- One free room of this type for every night of the range.
  select count(*) into v_free from public.fo_rooms r
   where r.restaurant_id = v_rest and r.branch_id = v_branch and r.room_type_id = p_room_type_id
     and r.active and not r.out_of_service
     and app.fo_room_free(r.id, p_arrival, p_departure);
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

-- ---------------------------------------------------------------- check in
-- p_room_id optional: left out, the first free clean room of the booked type is taken.
create or replace function public.fo_check_in(p_stay uuid, p_room_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; r public.fo_rooms; v_today date;
begin
  v_user := app.require_fo(array['fo.manage']);
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status = 'inhouse' then
    return jsonb_build_object('stay_id', s.id, 'room_id', s.room_id, 'repeat', true);
  end if;
  if s.status <> 'reserved' then raise exception 'This stay is %, so it cannot be checked in.', s.status; end if;

  v_today := app.business_today(v_branch);
  if s.arrival > v_today then raise exception 'This stay arrives on %, not today (%).', s.arrival, v_today; end if;

  if p_room_id is null then
    select * into r from public.fo_rooms
     where restaurant_id = v_rest and branch_id = v_branch and room_type_id = s.room_type_id
       and active and not out_of_service and housekeeping_status = 'clean'
       and app.fo_room_free(id, s.arrival, s.departure, s.id)
     order by room_number limit 1;
    if not found then raise exception 'No clean % is free. Check housekeeping.',
      (select name from public.fo_room_types where id = s.room_type_id); end if;
  else
    select * into r from public.fo_rooms
     where id = p_room_id and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'That room was not found.'; end if;
    if not r.active then raise exception 'Room % is not in use.', r.room_number; end if;
    if r.out_of_service then raise exception 'Room % is out of service (%).', r.room_number, r.oos_reason; end if;
    if r.housekeeping_status <> 'clean' then raise exception 'Room % is not clean yet.', r.room_number; end if;
    if not app.fo_room_free(r.id, s.arrival, s.departure, s.id) then
      raise exception 'Room % is taken for part of those dates.', r.room_number; end if;
  end if;

  update public.fo_stays set status = 'inhouse', room_id = r.id, checked_in_at = now() where id = s.id;
  update public.fo_rooms set housekeeping_status = 'dirty' where id = r.id;

  perform app.audit('fo_checked_in', 'fo_stay', s.id,
    jsonb_build_object('stay_no', s.stay_no, 'room_id', r.id, 'room_number', r.room_number));
  return jsonb_build_object('stay_id', s.id, 'room_id', r.id, 'room_number', r.room_number, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- change room
create or replace function public.fo_change_room(p_stay uuid, p_room_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; r public.fo_rooms; v_old uuid;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for the room change.'; end if;
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status <> 'inhouse' then raise exception 'Only an in-house stay can change room.'; end if;

  select * into r from public.fo_rooms where id = p_room_id and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That room was not found.'; end if;
  if r.id = s.room_id then raise exception 'The guest is already in room %.', r.room_number; end if;
  if not r.active then raise exception 'Room % is not in use.', r.room_number; end if;
  if r.out_of_service then raise exception 'Room % is out of service (%).', r.room_number, r.oos_reason; end if;
  if r.housekeeping_status <> 'clean' then raise exception 'Room % is not clean yet.', r.room_number; end if;
  if not app.fo_room_free(r.id, s.arrival, s.departure, s.id) then
    raise exception 'Room % is taken for part of those dates.', r.room_number; end if;

  v_old := s.room_id;
  update public.fo_stays set room_id = r.id where id = s.id;
  update public.fo_rooms set housekeeping_status = 'dirty' where id = r.id;
  update public.fo_rooms set housekeeping_status = 'dirty' where id = v_old;

  perform app.audit('fo_room_changed', 'fo_stay', s.id,
    jsonb_build_object('to_room', r.id, 'reason', btrim(p_reason)), jsonb_build_object('from_room', v_old));
  return jsonb_build_object('stay_id', s.id, 'room_id', r.id, 'room_number', r.room_number);
end $$;

-- ---------------------------------------------------------------- charges
-- p_kind 'room' is reserved for the night audit, which posts one room charge per stay per night.
create or replace function public.fo_post_charge(
  p_stay uuid, p_kind text, p_description text, p_unit_amount numeric,
  p_quantity numeric default 1, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; v_id uuid; v_net numeric; v_pct numeric; v_tax numeric; v_total numeric; v_today date;
begin
  v_user := app.require_fo(array['fo.manage']);

  if p_client_ref is not null then
    select id into v_id from public.fo_charges where restaurant_id = v_rest and client_ref = p_client_ref;
    if v_id is not null then return jsonb_build_object('charge_id', v_id, 'repeat', true); end if;
  end if;

  if p_kind = 'room' then raise exception 'Room charges are posted by the night audit.'; end if;
  if p_kind is null or p_kind not in ('food', 'laundry', 'telephone', 'minibar', 'misc') then
    raise exception 'Unknown charge type (%).', p_kind; end if;
  if coalesce(btrim(coalesce(p_description, '')), '') = '' then raise exception 'Describe the charge.'; end if;
  if p_unit_amount is null or p_unit_amount < 0 then raise exception 'The amount cannot be negative.'; end if;
  if coalesce(p_quantity, 1) <= 0 then raise exception 'The quantity must be more than zero.'; end if;

  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status not in ('reserved', 'inhouse') then
    raise exception 'This stay is %, so nothing can be posted to it.', s.status; end if;

  v_today := app.business_today(v_branch);
  v_net := round(p_unit_amount * coalesce(p_quantity, 1), 2);
  v_pct := app.fo_other_tax_pct(v_branch);
  v_tax := round(v_net * v_pct / 100, 2);
  v_total := v_net + v_tax;

  insert into public.fo_charges (restaurant_id, branch_id, stay_id, business_date, kind, description,
                                 quantity, unit_amount, net_amount, tax_pct, tax_amount, total_amount,
                                 created_by, client_ref)
  values (v_rest, v_branch, s.id, v_today, p_kind, btrim(p_description), coalesce(p_quantity, 1),
          p_unit_amount, v_net, v_pct, v_tax, v_total, v_user, p_client_ref)
  returning id into v_id;

  perform app.audit('fo_charge_posted', 'fo_charge', v_id, jsonb_build_object(
    'stay_id', s.id, 'kind', p_kind, 'description', btrim(p_description), 'total', v_total));
  return jsonb_build_object('charge_id', v_id, 'net', v_net, 'tax', v_tax, 'total', v_total, 'repeat', false);
end $$;

create or replace function public.fo_void_charge(p_charge uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        c public.fo_charges;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for the void.'; end if;
  select * into c from public.fo_charges
   where id = p_charge and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That charge was not found.'; end if;
  if c.voided_at is not null then return jsonb_build_object('charge_id', c.id, 'repeat', true); end if;
  if exists (select 1 from public.fo_stays s where s.id = c.stay_id and s.status = 'checked_out') then
    raise exception 'This folio is already closed. Raise a credit note instead.'; end if;

  update public.fo_charges set voided_at = now(), void_reason = btrim(p_reason), voided_by = v_user where id = c.id;
  perform app.audit('fo_charge_voided', 'fo_charge', c.id,
    jsonb_build_object('reason', btrim(p_reason)), jsonb_build_object('total', c.total_amount));
  return jsonb_build_object('charge_id', c.id, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- payments
create or replace function public.fo_take_payment(
  p_stay uuid, p_amount numeric, p_payment_method_id uuid default null,
  p_reference text default null, p_is_refund boolean default false, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; v_id uuid; v_method text; v_today date; v_bal numeric;
begin
  v_user := app.require_fo(array['fo.manage']);

  if p_client_ref is not null then
    select id into v_id from public.fo_payments where restaurant_id = v_rest and client_ref = p_client_ref;
    if v_id is not null then return jsonb_build_object('payment_id', v_id, 'repeat', true); end if;
  end if;

  if p_amount is null or p_amount <= 0 then raise exception 'The amount must be more than zero.'; end if;
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status = 'cancelled' then raise exception 'This stay is cancelled.'; end if;

  if p_payment_method_id is null then v_method := 'Cash';
  else
    select name into v_method from public.payment_methods
     where id = p_payment_method_id and restaurant_id = v_rest;
    if v_method is null then raise exception 'That payment method was not found.'; end if;
  end if;

  if coalesce(p_is_refund, false) then
    v_bal := app.fo_balance(s.id);
    if p_amount > -v_bal then
      raise exception 'The folio is owed %, so % cannot be refunded.', round(-v_bal, 2), round(p_amount, 2); end if;
  end if;

  v_today := app.business_today(v_branch);
  insert into public.fo_payments (restaurant_id, branch_id, stay_id, business_date, amount,
                                  payment_method_id, method_name, is_refund, reference, created_by, client_ref)
  values (v_rest, v_branch, s.id, v_today, p_amount, p_payment_method_id, v_method,
          coalesce(p_is_refund, false), p_reference, v_user, p_client_ref)
  returning id into v_id;

  perform app.audit(case when coalesce(p_is_refund, false) then 'fo_refund_paid' else 'fo_payment_taken' end,
    'fo_payment', v_id, jsonb_build_object('stay_id', s.id, 'amount', p_amount, 'method', v_method));
  return jsonb_build_object('payment_id', v_id, 'balance', app.fo_balance(s.id), 'repeat', false);
end $$;

create or replace function public.fo_void_payment(p_payment uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        p public.fo_payments;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for the void.'; end if;
  select * into p from public.fo_payments
   where id = p_payment and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That payment was not found.'; end if;
  if p.voided_at is not null then return jsonb_build_object('payment_id', p.id, 'repeat', true); end if;
  if exists (select 1 from public.fo_stays s where s.id = p.stay_id and s.status = 'checked_out') then
    raise exception 'This folio is already closed.'; end if;

  update public.fo_payments set voided_at = now(), void_reason = btrim(p_reason), voided_by = v_user where id = p.id;
  perform app.audit('fo_payment_voided', 'fo_payment', p.id,
    jsonb_build_object('reason', btrim(p_reason)), jsonb_build_object('amount', p.amount));
  return jsonb_build_object('payment_id', p.id, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- check out
-- p_payment_method_id given: whatever is owed is collected first, then the stay closes. One call, one trip.
create or replace function public.fo_check_out(
  p_stay uuid, p_payment_method_id uuid default null, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; v_bal numeric; v_collected numeric := 0;
begin
  v_user := app.require_fo(array['fo.manage']);
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status = 'checked_out' then
    return jsonb_build_object('stay_id', s.id, 'collected', 0, 'repeat', true); end if;
  if s.status <> 'inhouse' then raise exception 'This stay is %, so it cannot be checked out.', s.status; end if;

  v_bal := app.fo_balance(s.id);

  if v_bal < 0 then
    raise exception 'This folio is in credit by %. Refund it before checking out.', round(-v_bal, 2);
  end if;

  if v_bal > 0 then
    if p_payment_method_id is null then
      raise exception 'The guest owes %. Collect it, or pass a payment method to collect it now.', round(v_bal, 2);
    end if;
    perform public.fo_take_payment(s.id, v_bal, p_payment_method_id, 'Check-out', false, p_client_ref);
    v_collected := v_bal;
  end if;

  if app.fo_balance(s.id) <> 0 then
    raise exception 'The folio did not settle. Balance is still %.', round(app.fo_balance(s.id), 2);
  end if;

  update public.fo_stays set status = 'checked_out', checked_out_at = now() where id = s.id;
  update public.fo_rooms set housekeeping_status = 'dirty' where id = s.room_id;

  perform app.audit('fo_checked_out', 'fo_stay', s.id,
    jsonb_build_object('stay_no', s.stay_no, 'collected', v_collected));
  return jsonb_build_object('stay_id', s.id, 'collected', v_collected, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- cancel / no-show
create or replace function public.fo_cancel_stay(p_stay uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; v_paid numeric;
begin
  v_user := app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_reason, '')), '') = '' then raise exception 'Give a reason for the cancellation.'; end if;
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status = 'cancelled' then return jsonb_build_object('stay_id', s.id, 'repeat', true); end if;
  if s.status <> 'reserved' then raise exception 'Only a reservation can be cancelled; this one is %.', s.status; end if;

  -- Net of refunds: an advance that has been paid back no longer holds the cancellation up.
  select coalesce(sum(case when is_refund then -amount else amount end), 0) into v_paid
    from public.fo_payments where stay_id = s.id and voided_at is null;
  if v_paid > 0 then
    raise exception 'An advance of % is on this folio. Refund it before cancelling.', round(v_paid, 2); end if;

  update public.fo_stays set status = 'cancelled', cancelled_at = now(), cancel_reason = btrim(p_reason) where id = s.id;
  perform app.audit('fo_stay_cancelled', 'fo_stay', s.id, jsonb_build_object('reason', btrim(p_reason)));
  return jsonb_build_object('stay_id', s.id, 'repeat', false);
end $$;

create or replace function public.fo_mark_no_show(p_stay uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; v_today date;
begin
  v_user := app.require_fo(array['fo.manage']);
  select * into s from public.fo_stays
   where id = p_stay and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That stay was not found.'; end if;
  if s.status = 'no_show' then return jsonb_build_object('stay_id', s.id, 'repeat', true); end if;
  if s.status <> 'reserved' then raise exception 'Only a reservation can be a no-show; this one is %.', s.status; end if;

  v_today := app.business_today(v_branch);
  if s.arrival > v_today then raise exception 'This stay arrives on %, so it is not a no-show yet.', s.arrival; end if;

  update public.fo_stays set status = 'no_show', cancel_reason = nullif(btrim(coalesce(p_reason, '')), '') where id = s.id;
  perform app.audit('fo_no_show', 'fo_stay', s.id, jsonb_build_object('stay_no', s.stay_no));
  return jsonb_build_object('stay_id', s.id, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- housekeeping
create or replace function public.fo_set_room_status(
  p_room uuid, p_housekeeping text default null,
  p_out_of_service boolean default null, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        r public.fo_rooms; v_hk text; v_oos boolean;
begin
  v_user := app.require_fo(array['fo.housekeeping', 'fo.manage']);
  select * into r from public.fo_rooms where id = p_room and restaurant_id = v_rest and branch_id = v_branch for update;
  if not found then raise exception 'That room was not found.'; end if;

  v_hk := coalesce(p_housekeeping, r.housekeeping_status);
  if v_hk not in ('clean', 'dirty') then raise exception 'A room is either clean or dirty.'; end if;
  v_oos := coalesce(p_out_of_service, r.out_of_service);

  if v_oos and coalesce(btrim(coalesce(p_reason, r.oos_reason, '')), '') = '' then
    raise exception 'Give a reason for taking room % out of service.', r.room_number; end if;
  if v_oos and exists (select 1 from public.fo_stays s where s.room_id = r.id and s.status = 'inhouse') then
    raise exception 'Room % has a guest in it.', r.room_number; end if;

  update public.fo_rooms set
    housekeeping_status = v_hk, out_of_service = v_oos,
    oos_reason = case when v_oos then coalesce(nullif(btrim(coalesce(p_reason, '')), ''), r.oos_reason) else null end
   where id = r.id;

  perform app.audit('fo_room_status', 'fo_room', r.id, jsonb_build_object(
    'room_number', r.room_number, 'housekeeping', v_hk, 'out_of_service', v_oos),
    jsonb_build_object('housekeeping', r.housekeeping_status, 'out_of_service', r.out_of_service));
  return jsonb_build_object('room_id', r.id, 'housekeeping', v_hk, 'out_of_service', v_oos);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function
  public.fo_save_guest(text, text, text, text, text, text, text, text, text, uuid),
  public.fo_create_stay(uuid, uuid, date, date, numeric, int, int, text, text, uuid),
  public.fo_check_in(uuid, uuid),
  public.fo_change_room(uuid, uuid, text),
  public.fo_post_charge(uuid, text, text, numeric, numeric, uuid),
  public.fo_void_charge(uuid, text),
  public.fo_take_payment(uuid, numeric, uuid, text, boolean, uuid),
  public.fo_void_payment(uuid, text),
  public.fo_check_out(uuid, uuid, uuid),
  public.fo_cancel_stay(uuid, text),
  public.fo_mark_no_show(uuid, text),
  public.fo_set_room_status(uuid, text, boolean, text)
  from public, anon;
grant execute on function
  public.fo_save_guest(text, text, text, text, text, text, text, text, text, uuid),
  public.fo_create_stay(uuid, uuid, date, date, numeric, int, int, text, text, uuid),
  public.fo_check_in(uuid, uuid),
  public.fo_change_room(uuid, uuid, text),
  public.fo_post_charge(uuid, text, text, numeric, numeric, uuid),
  public.fo_void_charge(uuid, text),
  public.fo_take_payment(uuid, numeric, uuid, text, boolean, uuid),
  public.fo_void_payment(uuid, text),
  public.fo_check_out(uuid, uuid, uuid),
  public.fo_cancel_stay(uuid, text),
  public.fo_mark_no_show(uuid, text),
  public.fo_set_room_status(uuid, text, boolean, text)
  to authenticated, service_role;
