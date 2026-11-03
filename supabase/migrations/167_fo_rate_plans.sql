-- 167: Front Office rate plans (SNA Hospitality, batch B). Depends on 160-166.
-- New tables and functions; four Front Office functions are replaced (fo_create_stay, fo_amend_stay, fo_folio,
-- fo_night_audit_run) and one tax helper (app.fo_room_tax_pct). Nothing outside Front Office is touched. Safe to run again.
--
-- What a rate plan is (OPERA "rate code", Winsar "tariff", RMS "plan"):
--   * A plan has a code, a name and a meal plan: EP (room only), CP (with breakfast), MAP (breakfast + one meal),
--     AP (all meals).
--   * A plan carries rate rules per room type: a weekday rate, an optional weekend rate (Friday and Saturday nights),
--     an optional single-occupancy rate, an extra-adult and an extra-child charge above the included adults, and an
--     optional date window (a season). When two rules cover a night, the one with the narrower window wins.
--   * The booking asks for a quote, picks a plan, and the stay stores the rate of EVERY night (fo_stay_rates). The night
--     audit posts that night's stored rate, and the GST slab is chosen from that night's rate, because the slab is
--     decided per unit per day. A stay with no plan keeps the single nightly_rate, exactly as before.
--   * A manual rate typed at booking overrides the plan and is flat; the plan is still recorded on the stay.
--   * Room tariff below room_tax_exempt_below (default 1000) per night carries no GST. The sources we read disagree on
--     whether that band is exempt or 5%: CONFIRM WITH A LOCAL ACCOUNTANT. It is a setting, not code.

-- ---------------------------------------------------------------- 1. tables
alter table public.fo_branch_settings
  add column if not exists room_tax_exempt_below numeric(12,2) not null default 1000 check (room_tax_exempt_below >= 0);

create table if not exists public.fo_rate_plans (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  code text not null,
  name text not null,
  meal_plan text not null default 'EP' check (meal_plan in ('EP', 'CP', 'MAP', 'AP')),
  description text,
  display_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (restaurant_id, id),
  unique (restaurant_id, code)
);

create table if not exists public.fo_rate_rules (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  rate_plan_id uuid not null,
  room_type_id uuid not null,
  valid_from date,
  valid_to date,
  rate numeric(12,2) not null check (rate >= 0),
  weekend_rate numeric(12,2) check (weekend_rate is null or weekend_rate >= 0),
  single_rate numeric(12,2) check (single_rate is null or single_rate >= 0),
  included_adults int not null default 2 check (included_adults between 1 and 20),
  extra_adult numeric(12,2) not null default 0 check (extra_adult >= 0),
  extra_child numeric(12,2) not null default 0 check (extra_child >= 0),
  created_at timestamptz not null default now(),
  foreign key (restaurant_id, rate_plan_id) references public.fo_rate_plans(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, room_type_id) references public.fo_room_types(restaurant_id, id),
  constraint fo_rate_rules_window_check check (valid_from is null or valid_to is null or valid_to >= valid_from)
);
create index if not exists fo_rate_rules_plan_idx on public.fo_rate_rules (rate_plan_id, room_type_id);

alter table public.fo_stays add column if not exists rate_plan_id uuid;
alter table public.fo_stays drop constraint if exists fo_stays_rate_plan_fk;
alter table public.fo_stays add constraint fo_stays_rate_plan_fk
  foreign key (restaurant_id, rate_plan_id) references public.fo_rate_plans(restaurant_id, id);

create table if not exists public.fo_stay_rates (
  stay_id uuid not null,
  night date not null,
  restaurant_id uuid not null,
  branch_id uuid not null,
  rate numeric(12,2) not null check (rate >= 0),
  primary key (stay_id, night),
  foreign key (restaurant_id, stay_id) references public.fo_stays(restaurant_id, id) on delete cascade
);

do $$
declare t text;
begin
  foreach t in array array['fo_rate_plans', 'fo_rate_rules', 'fo_stay_rates'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from authenticated, anon', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
  end loop;
end $$;
create policy tenant_read on public.fo_rate_plans for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
create policy tenant_read on public.fo_rate_rules for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));
create policy tenant_read on public.fo_stay_rates for select to authenticated using (
  restaurant_id = (select app.current_restaurant_id()) and branch_id = (select app.current_branch_id())
  and ((select app.has_permission('fo.view')) or (select app.has_permission('fo.manage'))));

-- ---------------------------------------------------------------- 2. tax: low tariffs carry no GST
create or replace function app.fo_room_tax_pct(p_branch uuid, p_rate numeric) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce(p_rate, 0) < coalesce(s.room_tax_exempt_below, 1000) then 0
              when coalesce(p_rate, 0) > coalesce(s.room_tax_threshold, 7500) then coalesce(s.room_tax_pct_high, 18)
              else coalesce(s.room_tax_pct, 5) end
    from public.branches b left join public.fo_branch_settings s on s.branch_id = b.id
   where b.id = p_branch;
$$;
revoke all on function app.fo_room_tax_pct(uuid, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------- 3. rate arithmetic
-- The rate of one night under one plan for one room type, or null when the plan has no rule for that night.
create or replace function app.fo_plan_rate(p_plan uuid, p_type uuid, p_night date, p_adults int, p_children int)
returns numeric language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.fo_rate_rules; v numeric;
begin
  select * into r from public.fo_rate_rules x
   where x.rate_plan_id = p_plan and x.room_type_id = p_type
     and (x.valid_from is null or x.valid_from <= p_night) and (x.valid_to is null or x.valid_to >= p_night)
   order by (x.valid_from is not null and x.valid_to is not null) desc, x.valid_from desc nulls last, x.created_at desc
   limit 1;
  if not found then return null; end if;
  if coalesce(p_adults, 1) = 1 and coalesce(p_children, 0) = 0 and r.single_rate is not null then
    return r.single_rate; end if;
  v := case when r.weekend_rate is not null and extract(isodow from p_night) in (5, 6) then r.weekend_rate else r.rate end;
  return v + r.extra_adult * greatest(coalesce(p_adults, 1) - r.included_adults, 0)
           + r.extra_child * coalesce(p_children, 0);
end $$;

-- What a stay is charged for one night: the stored rate for that night, else the stay's flat rate.
create or replace function app.fo_night_rate(p_stay uuid, p_night date) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select r.rate from public.fo_stay_rates r where r.stay_id = p_stay and r.night = p_night),
                  (select s.nightly_rate from public.fo_stays s where s.id = p_stay));
$$;
revoke all on function app.fo_plan_rate(uuid, uuid, date, int, int), app.fo_night_rate(uuid, date)
  from public, anon, authenticated;

-- ---------------------------------------------------------------- 4. masters
create or replace function public.fo_save_rate_plan(
  p_code text, p_name text, p_meal_plan text default 'EP', p_description text default null,
  p_display_order int default 0, p_active boolean default true, p_plan_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_id uuid;
begin
  perform app.require_fo(array['fo.manage']);
  if coalesce(btrim(coalesce(p_code, '')), '') = '' then raise exception 'Give the rate plan a short code.'; end if;
  if coalesce(btrim(coalesce(p_name, '')), '') = '' then raise exception 'Give the rate plan a name.'; end if;
  if coalesce(p_meal_plan, 'EP') not in ('EP', 'CP', 'MAP', 'AP') then
    raise exception 'Meal plan must be EP, CP, MAP or AP.'; end if;

  if p_plan_id is null then
    insert into public.fo_rate_plans (restaurant_id, code, name, meal_plan, description, display_order, active)
    values (v_rest, upper(btrim(p_code)), btrim(p_name), coalesce(p_meal_plan, 'EP'),
            nullif(btrim(coalesce(p_description, '')), ''), coalesce(p_display_order, 0), coalesce(p_active, true))
    returning id into v_id;
    perform app.audit('fo_rate_plan_created', 'fo_rate_plan', v_id, jsonb_build_object('code', upper(btrim(p_code))));
    return jsonb_build_object('rate_plan_id', v_id, 'created', true);
  end if;

  update public.fo_rate_plans set code = upper(btrim(p_code)), name = btrim(p_name),
         meal_plan = coalesce(p_meal_plan, meal_plan), description = nullif(btrim(coalesce(p_description, '')), ''),
         display_order = coalesce(p_display_order, display_order), active = coalesce(p_active, active)
   where id = p_plan_id and restaurant_id = v_rest returning id into v_id;
  if v_id is null then raise exception 'That rate plan was not found.'; end if;
  perform app.audit('fo_rate_plan_updated', 'fo_rate_plan', v_id, jsonb_build_object('code', upper(btrim(p_code))));
  return jsonb_build_object('rate_plan_id', v_id, 'created', false);
end $$;

create or replace function public.fo_save_rate_rule(
  p_plan_id uuid, p_room_type_id uuid, p_rate numeric, p_weekend_rate numeric default null,
  p_single_rate numeric default null, p_included_adults int default 2, p_extra_adult numeric default 0,
  p_extra_child numeric default 0, p_valid_from date default null, p_valid_to date default null,
  p_rule_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_id uuid;
begin
  perform app.require_fo(array['fo.manage']);
  if not exists (select 1 from public.fo_rate_plans where id = p_plan_id and restaurant_id = v_rest) then
    raise exception 'That rate plan was not found.'; end if;
  if not exists (select 1 from public.fo_room_types where id = p_room_type_id and restaurant_id = v_rest) then
    raise exception 'That room type was not found.'; end if;
  if p_rate is null or p_rate < 0 then raise exception 'Give a rate of zero or more.'; end if;
  if p_valid_from is not null and p_valid_to is not null and p_valid_to < p_valid_from then
    raise exception 'The season ends before it starts.'; end if;

  if p_rule_id is null then
    insert into public.fo_rate_rules (restaurant_id, rate_plan_id, room_type_id, valid_from, valid_to, rate, weekend_rate,
                                      single_rate, included_adults, extra_adult, extra_child)
    values (v_rest, p_plan_id, p_room_type_id, p_valid_from, p_valid_to, p_rate, p_weekend_rate, p_single_rate,
            coalesce(p_included_adults, 2), coalesce(p_extra_adult, 0), coalesce(p_extra_child, 0))
    returning id into v_id;
    perform app.audit('fo_rate_rule_created', 'fo_rate_rule', v_id,
      jsonb_build_object('plan', p_plan_id, 'room_type', p_room_type_id, 'rate', p_rate));
    return jsonb_build_object('rule_id', v_id, 'created', true);
  end if;

  update public.fo_rate_rules set rate_plan_id = p_plan_id, room_type_id = p_room_type_id, valid_from = p_valid_from,
         valid_to = p_valid_to, rate = p_rate, weekend_rate = p_weekend_rate, single_rate = p_single_rate,
         included_adults = coalesce(p_included_adults, included_adults), extra_adult = coalesce(p_extra_adult, 0),
         extra_child = coalesce(p_extra_child, 0)
   where id = p_rule_id and restaurant_id = v_rest returning id into v_id;
  if v_id is null then raise exception 'That rate rule was not found.'; end if;
  perform app.audit('fo_rate_rule_updated', 'fo_rate_rule', v_id, jsonb_build_object('rate', p_rate));
  return jsonb_build_object('rule_id', v_id, 'created', false);
end $$;

-- A rule is configuration, not history: every stay already booked keeps the per-night rates it stored.
create or replace function public.fo_delete_rate_rule(p_rule_id uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_id uuid;
begin
  perform app.require_fo(array['fo.manage']);
  delete from public.fo_rate_rules where id = p_rule_id and restaurant_id = v_rest returning id into v_id;
  if v_id is null then raise exception 'That rate rule was not found.'; end if;
  perform app.audit('fo_rate_rule_deleted', 'fo_rate_rule', v_id, null);
  return jsonb_build_object('rule_id', v_id);
end $$;

-- Plans with their rules, for the setup screen.
create or replace function public.fo_rate_setup() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  return jsonb_build_object('plans', coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.id, 'code', p.code, 'name', p.name, 'meal_plan', p.meal_plan, 'description', p.description,
      'display_order', p.display_order, 'active', p.active,
      'rules', coalesce((select jsonb_agg(jsonb_build_object(
          'id', r.id, 'room_type_id', r.room_type_id, 'valid_from', r.valid_from, 'valid_to', r.valid_to,
          'rate', r.rate, 'weekend_rate', r.weekend_rate, 'single_rate', r.single_rate,
          'included_adults', r.included_adults, 'extra_adult', r.extra_adult, 'extra_child', r.extra_child)
          order by r.room_type_id, r.valid_from nulls first, r.created_at)
        from public.fo_rate_rules r where r.rate_plan_id = p.id), '[]'::jsonb))
      order by p.display_order, p.name)
    from public.fo_rate_plans p where p.restaurant_id = v_rest), '[]'::jsonb));
end $$;

-- The booking form's price list: the standard rate plus every active plan that can price every night asked for.
create or replace function public.fo_quote(
  p_room_type uuid, p_arrival date, p_departure date, p_adults int default 1, p_children int default 0) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); t public.fo_room_types; p public.fo_rate_plans;
        v_opts jsonb := '[]'::jsonb; v_nights jsonb; v_total numeric; v_rate numeric; d date; v_missing date;
begin
  perform app.require_fo(array['fo.view', 'fo.manage']);
  if p_arrival is null or p_departure is null or p_departure <= p_arrival then
    raise exception 'Give an arrival date and a later departure date.'; end if;
  if p_departure - p_arrival > 366 then raise exception 'A stay can be at most 366 nights.'; end if;
  select * into t from public.fo_room_types where id = p_room_type and restaurant_id = v_rest;
  if not found then raise exception 'That room type was not found.'; end if;

  select jsonb_agg(jsonb_build_object('night', g.day::date, 'rate', t.base_rate) order by g.day) into v_nights
    from generate_series(p_arrival, p_departure - 1, interval '1 day') as g(day);
  v_opts := v_opts || jsonb_build_object('rate_plan_id', null, 'code', 'RACK', 'name', 'Standard rate', 'meal_plan', 'EP',
    'available', true, 'total', t.base_rate * (p_departure - p_arrival), 'average', t.base_rate, 'nights', v_nights);

  for p in select * from public.fo_rate_plans where restaurant_id = v_rest and active order by display_order, name loop
    v_total := 0; v_nights := '[]'::jsonb; v_missing := null;
    for d in select x::date from generate_series(p_arrival, p_departure - 1, interval '1 day') x loop
      v_rate := app.fo_plan_rate(p.id, p_room_type, d, p_adults, p_children);
      if v_rate is null then v_missing := d; exit; end if;
      v_total := v_total + v_rate;
      v_nights := v_nights || jsonb_build_object('night', d, 'rate', v_rate);
    end loop;
    if v_missing is null then
      v_opts := v_opts || jsonb_build_object('rate_plan_id', p.id, 'code', p.code, 'name', p.name, 'meal_plan', p.meal_plan,
        'available', true, 'total', v_total, 'average', round(v_total / (p_departure - p_arrival), 2), 'nights', v_nights);
    elsif exists (select 1 from public.fo_rate_rules r where r.rate_plan_id = p.id and r.room_type_id = p_room_type) then
      -- The plan prices this room type but not every night (a season ends): say so instead of hiding it.
      v_opts := v_opts || jsonb_build_object('rate_plan_id', p.id, 'code', p.code, 'name', p.name, 'meal_plan', p.meal_plan,
        'available', false, 'reason', 'No rate for ' || v_missing::text);
    end if;
  end loop;
  return jsonb_build_object('room_type', t.name, 'nights', p_departure - p_arrival, 'options', v_opts);
end $$;

-- ---------------------------------------------------------------- 5. create a stay (adds p_rate_plan_id)
drop function if exists public.fo_create_stay(uuid, uuid, date, date, numeric, int, int, text, text, uuid);
create or replace function public.fo_create_stay(
  p_guest_id uuid, p_room_type_id uuid, p_arrival date, p_departure date,
  p_nightly_rate numeric default null, p_adults int default 1, p_children int default 0,
  p_source text default 'walk_in', p_notes text default null, p_client_ref uuid default null,
  p_rate_plan_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        v_today date; v_rate numeric; v_type public.fo_room_types; v_stay uuid; v_no int; v_free int;
        v_blocked boolean; v_why text; v_plan public.fo_rate_plans; v_night date; v_nr numeric;
        v_rates jsonb := '[]'::jsonb;
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
  if p_departure - p_arrival > 366 then raise exception 'A stay can be at most 366 nights.'; end if;

  select * into v_type from public.fo_room_types where id = p_room_type_id and restaurant_id = v_rest and active;
  if not found then raise exception 'That room type was not found.'; end if;
  if coalesce(p_adults, 1) + coalesce(p_children, 0) > v_type.max_occupancy then
    raise exception '% holds % people; you asked for %.', v_type.name, v_type.max_occupancy,
      coalesce(p_adults, 1) + coalesce(p_children, 0);
  end if;

  if p_nightly_rate is not null and p_nightly_rate < 0 then raise exception 'The rate cannot be negative.'; end if;

  if p_rate_plan_id is not null then
    select * into v_plan from public.fo_rate_plans where id = p_rate_plan_id and restaurant_id = v_rest and active;
    if not found then raise exception 'That rate plan was not found.'; end if;
    if p_nightly_rate is null then
      for v_night in select x::date from generate_series(p_arrival, p_departure - 1, interval '1 day') x loop
        v_nr := app.fo_plan_rate(v_plan.id, p_room_type_id, v_night, p_adults, p_children);
        if v_nr is null then
          raise exception 'The rate plan % has no rate for % on %.', v_plan.code, v_type.name, v_night; end if;
        v_rates := v_rates || jsonb_build_object('night', v_night, 'rate', v_nr);
      end loop;
      v_rate := (v_rates -> 0 ->> 'rate')::numeric;
    end if;
  end if;
  v_rate := coalesce(p_nightly_rate, v_rate, v_type.base_rate);

  v_free := app.fo_type_free(v_branch, p_room_type_id, p_arrival, p_departure);
  if v_free = 0 then
    raise exception 'No % is free from % to %.', v_type.name, p_arrival, p_departure;
  end if;

  v_no := app.fo_next_stay_no(v_rest);
  insert into public.fo_stays (restaurant_id, branch_id, stay_no, guest_id, room_type_id, arrival, departure,
                               adults, children, nightly_rate, status, source, notes, booked_on, created_by, client_ref,
                               rate_plan_id)
  values (v_rest, v_branch, v_no, p_guest_id, p_room_type_id, p_arrival, p_departure,
          coalesce(p_adults, 1), coalesce(p_children, 0), v_rate, 'reserved',
          coalesce(p_source, 'walk_in'), p_notes, v_today, v_user, p_client_ref, p_rate_plan_id)
  returning id into v_stay;

  if jsonb_array_length(v_rates) > 0 then
    insert into public.fo_stay_rates (stay_id, night, restaurant_id, branch_id, rate)
    select v_stay, (e ->> 'night')::date, v_rest, v_branch, (e ->> 'rate')::numeric from jsonb_array_elements(v_rates) e;
  end if;

  perform app.audit('fo_stay_created', 'fo_stay', v_stay, jsonb_build_object(
    'stay_no', v_no, 'guest_id', p_guest_id, 'arrival', p_arrival, 'departure', p_departure, 'rate', v_rate,
    'rate_plan', v_plan.code));
  return jsonb_build_object('stay_id', v_stay, 'stay_no', v_no, 'nightly_rate', v_rate, 'repeat', false);
end $$;

-- ---------------------------------------------------------------- 6. amend a stay (keeps the per-night rates true)
create or replace function public.fo_amend_stay(
  p_stay uuid, p_departure date default null, p_nightly_rate numeric default null,
  p_reason text default null, p_notes text default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id(); v_user uuid;
        s public.fo_stays; v_today date; v_dep date; v_rate numeric; v_last_charged date; v_night date; v_nr numeric;
        v_rate_changed boolean;
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
  v_rate_changed := p_nightly_rate is not null and p_nightly_rate <> s.nightly_rate;

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

  -- A new flat rate replaces the stored rate of every night still to come; nights already charged keep what was posted.
  if v_rate_changed then
    delete from public.fo_stay_rates where stay_id = s.id and night >= greatest(v_today, s.arrival);
  end if;
  -- A shorter stay drops the rates of the nights it no longer has.
  if v_dep < s.departure then
    delete from public.fo_stay_rates where stay_id = s.id and night >= v_dep;
  end if;
  -- A longer stay on a rate plan takes the plan's rate for the new nights; with no plan rule it keeps the flat rate.
  if v_dep > s.departure and s.rate_plan_id is not null and not v_rate_changed
     and exists (select 1 from public.fo_stay_rates where stay_id = s.id) then
    for v_night in select x::date from generate_series(s.departure, v_dep - 1, interval '1 day') x loop
      v_nr := app.fo_plan_rate(s.rate_plan_id, s.room_type_id, v_night, s.adults, s.children);
      if v_nr is not null then
        insert into public.fo_stay_rates (stay_id, night, restaurant_id, branch_id, rate)
        values (s.id, v_night, v_rest, v_branch, v_nr) on conflict (stay_id, night) do nothing;
      end if;
    end loop;
  end if;

  perform app.audit('fo_stay_amended', 'fo_stay', s.id,
    jsonb_build_object('departure', v_dep, 'rate', v_rate, 'reason', btrim(p_reason)),
    jsonb_build_object('departure', s.departure, 'rate', s.nightly_rate));
  return jsonb_build_object('stay_id', s.id, 'departure', v_dep, 'nightly_rate', v_rate, 'nights', v_dep - s.arrival);
end $$;

-- ---------------------------------------------------------------- 7. the folio read (adds plan, schedule, guest billing)
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
      'rate_plan', (select pl.name from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
      'rate_plan_code', (select pl.code from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
      'meal_plan', (select pl.meal_plan from public.fo_rate_plans pl where pl.id = s.rate_plan_id),
      'rate_schedule', coalesce((select jsonb_agg(jsonb_build_object('night', r.night, 'rate', r.rate) order by r.night)
                                   from public.fo_stay_rates r where r.stay_id = s.id), '[]'::jsonb),
      'guest', (select jsonb_build_object('guest_id', g.id, 'full_name', g.full_name, 'phone', g.phone, 'email', g.email)
                  from public.fo_guests g where g.restaurant_id = s.restaurant_id and g.id = s.guest_id)),
    'charges', v_charges, 'payments', v_payments,
    'totals', jsonb_build_object('charged', v_charged, 'paid', v_paid, 'refunded', v_refunded,
                                 'balance', v_charged - v_paid + v_refunded));
end $$;

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
    select st.id, st.stay_no, app.fo_night_rate(st.id, v_date) as nightly_rate from public.fo_stays st
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

-- ---------------------------------------------------------------- 8. grants
revoke all on function
  public.fo_save_rate_plan(text, text, text, text, int, boolean, uuid),
  public.fo_save_rate_rule(uuid, uuid, numeric, numeric, numeric, int, numeric, numeric, date, date, uuid),
  public.fo_delete_rate_rule(uuid), public.fo_rate_setup(), public.fo_quote(uuid, date, date, int, int),
  public.fo_create_stay(uuid, uuid, date, date, numeric, int, int, text, text, uuid, uuid),
  public.fo_amend_stay(uuid, date, numeric, text, text), public.fo_folio(uuid),
  public.fo_night_audit_run(date) from public, anon;
grant execute on function
  public.fo_save_rate_plan(text, text, text, text, int, boolean, uuid),
  public.fo_save_rate_rule(uuid, uuid, numeric, numeric, numeric, int, numeric, numeric, date, date, uuid),
  public.fo_delete_rate_rule(uuid), public.fo_rate_setup(), public.fo_quote(uuid, date, date, int, int),
  public.fo_create_stay(uuid, uuid, date, date, numeric, int, int, text, text, uuid, uuid),
  public.fo_amend_stay(uuid, date, numeric, text, text), public.fo_folio(uuid),
  public.fo_night_audit_run(date) to authenticated, service_role;
