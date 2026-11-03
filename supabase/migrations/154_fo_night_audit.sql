-- 154: Front Office night audit (SNA Hospitality). Depends on 152 and 153. Additive only.
--
-- What one run does, for one property and one business date:
--   1. Turns every reservation that should have arrived by now and never did into a no-show.
--   2. Posts one room charge per in-house stay for that night, with tax by the tariff slab. A stay that leaves
--      on the audited date gets nothing: the night it did not sleep is not a night it pays for.
--   3. Writes the night's numbers (occupancy, ADR, RevPAR, room and other revenue, collections) to fo_night_audits.
--
-- It does NOT move a business date. The date comes from app.business_today(branch), the same source the POS uses, so a
-- room charge and a restaurant bill from the same evening always land on the same day. The unique index on
-- (branch_id, business_date) is what stops a second run, and the unique index on fo_charges (stay_id, business_date)
-- for live room charges is what stops a double posting if a run is interrupted halfway.
--
-- A re-run of a date already audited returns the stored numbers and changes nothing, so a reception that taps twice
-- does no damage.
-- Safe to run again.

create or replace function public.fo_night_audit_run(p_business_date date default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        v_date date; a public.fo_night_audits; s record;
        v_no_shows int := 0; v_posted int := 0;
        v_rooms_avail int := 0; v_rooms_sold int := 0;
        v_room_rev numeric := 0; v_other_rev numeric := 0; v_collect numeric := 0;
        v_occ numeric := 0; v_adr numeric := 0; v_revpar numeric := 0;
        v_pct numeric; v_tax numeric; v_total numeric;
begin
  v_user := app.require_fo(array['fo.night_audit']);
  v_date := coalesce(p_business_date, app.business_today(v_branch));
  if v_date is null then raise exception 'This outlet has no business date.'; end if;
  if v_date > app.business_today(v_branch) then
    raise exception 'The night audit cannot run for a future date (%).', v_date; end if;

  -- Already audited: give back what was recorded, touch nothing.
  select * into a from public.fo_night_audits where branch_id = v_branch and business_date = v_date;
  if found then
    return jsonb_build_object('business_date', a.business_date, 'repeat', true,
      'rooms_available', a.rooms_available, 'rooms_sold', a.rooms_sold, 'occupancy_pct', a.occupancy_pct,
      'room_revenue', a.room_revenue, 'other_revenue', a.other_revenue, 'collections', a.collections,
      'adr', a.adr, 'revpar', a.revpar, 'no_shows', a.no_shows, 'charges_posted', a.charges_posted);
  end if;

  -- 1. no-shows: due to arrive on or before this date and never checked in.
  update public.fo_stays set status = 'no_show'
   where restaurant_id = v_rest and branch_id = v_branch and status = 'reserved' and arrival <= v_date;
  get diagnostics v_no_shows = row_count;

  -- 2. one room charge per in-house stay for this night.
  for s in
    select st.id, st.stay_no, st.nightly_rate from public.fo_stays st
     where st.restaurant_id = v_rest and st.branch_id = v_branch and st.status = 'inhouse'
       and st.arrival <= v_date and st.departure > v_date
       and not exists (select 1 from public.fo_charges c
                        where c.stay_id = st.id and c.business_date = v_date
                          and c.kind = 'room' and c.voided_at is null)
     order by st.stay_no
  loop
    v_pct := app.fo_room_tax_pct(v_branch, s.nightly_rate);
    v_tax := round(s.nightly_rate * v_pct / 100, 2);
    v_total := s.nightly_rate + v_tax;
    insert into public.fo_charges (restaurant_id, branch_id, stay_id, business_date, kind, description,
                                   quantity, unit_amount, net_amount, tax_pct, tax_amount, total_amount, created_by)
    values (v_rest, v_branch, s.id, v_date, 'room', 'Room charge ' || v_date::text,
            1, s.nightly_rate, s.nightly_rate, v_pct, v_tax, v_total, v_user);
    v_posted := v_posted + 1;
  end loop;

  -- 3. the night's numbers.
  select count(*) into v_rooms_avail from public.fo_rooms
   where restaurant_id = v_rest and branch_id = v_branch and active and not out_of_service;

  -- Rooms sold = the room nights actually charged for this date. Counting stays instead would count a guest who
  -- checked out this morning (they did not sleep tonight) and would count one room twice if it was let again the
  -- same day. Taking it from the charges also keeps ADR = room revenue / rooms sold true by construction.
  select count(*) into v_rooms_sold from public.fo_charges c
   where c.restaurant_id = v_rest and c.branch_id = v_branch and c.business_date = v_date
     and c.kind = 'room' and c.voided_at is null;

  select coalesce(sum(c.net_amount) filter (where c.kind = 'room'), 0),
         coalesce(sum(c.net_amount) filter (where c.kind <> 'room'), 0)
    into v_room_rev, v_other_rev
    from public.fo_charges c
   where c.restaurant_id = v_rest and c.branch_id = v_branch and c.business_date = v_date and c.voided_at is null;

  select coalesce(sum(case when p.is_refund then -p.amount else p.amount end), 0) into v_collect
    from public.fo_payments p
   where p.restaurant_id = v_rest and p.branch_id = v_branch and p.business_date = v_date and p.voided_at is null;

  if v_rooms_avail > 0 then
    v_occ := round(v_rooms_sold::numeric * 100 / v_rooms_avail, 2);
    v_revpar := round(v_room_rev / v_rooms_avail, 2);
  end if;
  if v_rooms_sold > 0 then v_adr := round(v_room_rev / v_rooms_sold, 2); end if;

  insert into public.fo_night_audits (restaurant_id, branch_id, business_date, rooms_available, rooms_sold,
                                      occupancy_pct, room_revenue, other_revenue, collections, adr, revpar,
                                      no_shows, charges_posted, run_by)
  values (v_rest, v_branch, v_date, v_rooms_avail, v_rooms_sold, v_occ, v_room_rev, v_other_rev,
          v_collect, v_adr, v_revpar, v_no_shows, v_posted, v_user);

  perform app.audit('fo_night_audit', 'fo_night_audit', null, jsonb_build_object(
    'business_date', v_date, 'rooms_sold', v_rooms_sold, 'occupancy_pct', v_occ,
    'room_revenue', v_room_rev, 'no_shows', v_no_shows, 'charges_posted', v_posted));

  return jsonb_build_object('business_date', v_date, 'repeat', false,
    'rooms_available', v_rooms_avail, 'rooms_sold', v_rooms_sold, 'occupancy_pct', v_occ,
    'room_revenue', v_room_rev, 'other_revenue', v_other_rev, 'collections', v_collect,
    'adr', v_adr, 'revpar', v_revpar, 'no_shows', v_no_shows, 'charges_posted', v_posted);
end $$;

-- The reception dashboard: arrivals, in-house, departures and the last audit.
create or replace function public.fo_day_sheet(p_business_date date default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
        v_date date; v_arr jsonb; v_in jsonb; v_dep jsonb; v_audit jsonb;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  v_date := coalesce(p_business_date, app.business_today(v_branch));

  select coalesce(jsonb_agg(jsonb_build_object('stay_id', s.id, 'stay_no', s.stay_no, 'guest_name', g.full_name,
           'room_type', rt.name, 'nights', (s.departure - s.arrival), 'rate', s.nightly_rate,
           'adults', s.adults, 'children', s.children) order by s.stay_no), '[]'::jsonb)
    into v_arr
    from public.fo_stays s
    join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
    join public.fo_room_types rt on rt.restaurant_id = s.restaurant_id and rt.id = s.room_type_id
   where s.restaurant_id = v_rest and s.branch_id = v_branch and s.status = 'reserved' and s.arrival = v_date;

  select coalesce(jsonb_agg(jsonb_build_object('stay_id', s.id, 'stay_no', s.stay_no, 'guest_name', g.full_name,
           'room_number', r.room_number, 'departure', s.departure, 'balance', app.fo_balance(s.id))
           order by r.room_number), '[]'::jsonb)
    into v_in
    from public.fo_stays s
    join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
    left join public.fo_rooms r on r.id = s.room_id
   where s.restaurant_id = v_rest and s.branch_id = v_branch and s.status = 'inhouse';

  select coalesce(jsonb_agg(jsonb_build_object('stay_id', s.id, 'stay_no', s.stay_no, 'guest_name', g.full_name,
           'room_number', r.room_number, 'balance', app.fo_balance(s.id)) order by r.room_number), '[]'::jsonb)
    into v_dep
    from public.fo_stays s
    join public.fo_guests g on g.restaurant_id = s.restaurant_id and g.id = s.guest_id
    left join public.fo_rooms r on r.id = s.room_id
   where s.restaurant_id = v_rest and s.branch_id = v_branch and s.status = 'inhouse' and s.departure = v_date;

  select to_jsonb(x) into v_audit from (
    select business_date, rooms_available, rooms_sold, occupancy_pct, room_revenue, other_revenue,
           collections, adr, revpar, no_shows, charges_posted, run_at
      from public.fo_night_audits
     where branch_id = v_branch order by business_date desc limit 1) x;

  return jsonb_build_object('business_date', v_date, 'arrivals', v_arr, 'in_house', v_in,
    'departures', v_dep, 'last_audit', coalesce(v_audit, 'null'::jsonb),
    'audited', exists (select 1 from public.fo_night_audits where branch_id = v_branch and business_date = v_date));
end $$;

revoke all on function public.fo_night_audit_run(date), public.fo_day_sheet(date) from public, anon;
grant execute on function public.fo_night_audit_run(date), public.fo_day_sheet(date) to authenticated, service_role;
