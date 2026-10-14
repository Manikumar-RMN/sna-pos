-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928175212, name '070_optional_shifts_day_cutoff_sessions'. This is the SQL that actually ran.

alter table public.branch_settings add column if not exists shifts_enabled boolean not null default false;
alter table public.branch_settings add column if not exists day_cutoff time not null default '04:00';
update public.branch_settings set shifts_enabled = false;

create or replace function app.auto_shift(p_branch uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v uuid; v_on boolean; v_rest uuid; v_user uuid;
begin
  select id into v from public.shifts where branch_id = p_branch and status = 'open' order by opened_at desc limit 1;
  if v is not null then return v; end if;
  select coalesce(bs.shifts_enabled, false), b.restaurant_id into v_on, v_rest
    from public.branches b left join public.branch_settings bs on bs.branch_id = b.id where b.id = p_branch;
  if v_rest is null or v_on then return null; end if;
  perform pg_advisory_xact_lock(hashtext('auto_shift:' || p_branch::text));
  select id into v from public.shifts where branch_id = p_branch and status = 'open' limit 1;
  if v is not null then return v; end if;
  v_user := coalesce(app.current_user_id(),
    (select u.id from public.users u join public.roles r on r.id = u.role_id
      where u.restaurant_id = v_rest and r.name = 'Owner' order by u.created_at limit 1));
  insert into public.shifts (restaurant_id, branch_id, opened_by, opening_float, opened_at, status, notes)
  values (v_rest, p_branch, v_user, 0, now(), 'open', 'Automatic (shifts are off)')
  returning id into v;
  return v;
end $$;

create or replace function app.close_auto_shifts(p_branch uuid, p_counted numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s record; v_exp numeric(14,2);
begin
  if coalesce((select shifts_enabled from public.branch_settings where branch_id = p_branch), false) then return; end if;
  for s in select id from public.shifts where branch_id = p_branch and status = 'open' for update loop
    v_exp := (app.shift_figures(s.id)->>'expected_cash')::numeric;
    update public.shifts set status = 'closed', closed_at = now(), closed_by = app.current_user_id(), expected_cash = v_exp,
           counted_cash = round(p_counted, 2), cash_variance = case when p_counted is null then null else round(p_counted, 2) - v_exp end
     where id = s.id;
    if p_counted is not null then
      perform app.audit('shift.close', 'shifts', s.id,
        jsonb_build_object('expected_cash', v_exp, 'counted_cash', round(p_counted, 2), 'variance', round(p_counted, 2) - v_exp));
    end if;
  end loop;
end $$;

do $$
declare
  f text; d text; n text;
  pats text[][] := array[
    ['public.create_order(jsonb,text,uuid,uuid,uuid,numeric,numeric,text,boolean,jsonb,text,uuid)',
     '(select s\.id into v_shift from public\.shifts s\s+where s\.branch_id = v_branch and s\.status = ''open'' order by s\.opened_at desc limit 1;)',
     '\1 if v_shift is null then v_shift := app.auto_shift(v_branch); end if;'],
    ['public.sync_offline_bill(jsonb)',
     '(select s\.id into v_shift from public\.shifts s\s+where s\.branch_id = v_branch and s\.status = ''open'' order by s\.opened_at desc limit 1;)',
     '\1 if v_shift is null then v_shift := app.auto_shift(v_branch); end if;'],
    ['public.pay_order(uuid,uuid,numeric,numeric,text,uuid)',
     '(select id into v_shift from public\.shifts\s+where branch_id = o\.branch_id and status = ''open'' limit 1;)',
     '\1 if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;'],
    ['public.split_order(uuid,jsonb)',
     '(select id into v_shift from public\.shifts\s+where branch_id = o\.branch_id and status = ''open'' limit 1;)',
     '\1 if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;'],
    ['public.issue_credit_note(uuid,numeric,uuid,text)',
     '(select id into v_shift from public\.shifts\s+where branch_id = o\.branch_id and status = ''open'' limit 1;)',
     '\1 if v_shift is null then v_shift := app.auto_shift(o.branch_id); end if;'],
    ['public.issue_gift_card(numeric,uuid,text,text,integer)',
     '(select id into v_shift from public\.shifts\s+where branch_id = v_branch and status = ''open'' limit 1;)',
     '\1 if v_shift is null then v_shift := app.auto_shift(v_branch); end if;'],
    ['public.record_cash_movement(text,numeric,text)',
     '(select id into v_shift from public\.shifts\s+where branch_id = app\.current_branch_id\(\) and status = ''open'' limit 1;)',
     '\1 if v_shift is null then v_shift := app.auto_shift(app.current_branch_id()); end if;'],
    ['public.add_order_items(uuid,jsonb)',
     '(if not exists \(\s*select 1 from public\.shifts\s+where branch_id = o\.branch_id and status = ''open''\s*\))',
     'perform app.auto_shift(o.branch_id); \1'],
    ['public.reopen_day(text)',
     '(if exists \(\s*select 1 from public\.shifts\s+where branch_id = v_branch and status = ''open''\s*\))',
     'perform app.close_auto_shifts(v_branch, null); \1'],
    ['app.z_report(uuid)',
     '(''by_type'', v_types,)',
     '\1 ''sessions'', (select coalesce(jsonb_agg(jsonb_build_object(''session'', sn, ''bills'', c, ''total'', t) order by first_at), ''[]''::jsonb) from (select coalesce(o.session_name, ''Other'') sn, count(*) c, sum(o.grand_total) t, min(o.created_at) first_at from public.orders o where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = ''completed'' and o.merged_into is null group by 1) ss),']
  ];
  i int;
begin
  for i in 1 .. array_length(pats, 1) loop
    f := pats[i][1];
    d := pg_get_functiondef(f::regprocedure);
    n := regexp_replace(d, pats[i][2], pats[i][3]);
    if n = d then raise exception 'Patch did not apply to %', f; end if;
    execute n;
  end loop;
end $$;

drop function if exists public.close_day(text);
create or replace function public.close_day(p_notes text default null, p_counted_cash numeric default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := app.require_permission('day.close');
  v_branch uuid := app.current_branch_id(); d public.business_days; v_list text; v_z jsonb;
begin
  select * into d from public.business_days where branch_id = v_branch and status = 'open' for update;
  if not found then raise exception 'There is no open day to close.'; end if;
  if p_counted_cash is not null and p_counted_cash < 0 then raise exception 'The counted cash cannot be negative.'; end if;
  select string_agg(bill_number, ', ' order by created_at) into v_list from (
    select bill_number, created_at from public.orders
     where branch_id = v_branch and business_date = d.business_date and status = 'completed'
       and payment_status in ('unpaid', 'partial') and merged_into is null limit 20) x;
  if v_list is not null then
    raise exception 'These bills are not paid yet: %. Take payment, put them on a pay-later account, or void them before closing the day.', v_list;
  end if;
  perform app.close_auto_shifts(v_branch, p_counted_cash);
  if exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') then
    raise exception 'Close the open shift first (count the cash on the Shift screen), then close the day.';
  end if;
  update public.business_days set status = 'closed', closed_at = now(), closed_by = v_user,
         close_notes = nullif(left(trim(coalesce(p_notes, '')), 300), '')
   where id = d.id;
  v_z := app.z_report(d.id);
  update public.business_days set z_report = v_z where id = d.id;
  update public.business_days set status = 'open' where branch_id = v_branch and status = 'parked';
  perform app.audit('day.close', 'business_days', d.id,
    jsonb_build_object('business_date', d.business_date, 'total_billed', v_z->'total_billed', 'bills', v_z->'bills'));
  return v_z;
end $$;
revoke all on function public.close_day(text, numeric) from public, anon;
grant execute on function public.close_day(text, numeric) to authenticated;

create or replace function app.business_today(p_branch uuid) returns date
language sql stable security definer set search_path = public, pg_temp as $$
  select ((now() at time zone coalesce(b.timezone, r.timezone, 'UTC')) - coalesce(bs.day_cutoff, '04:00'::time)::interval)::date
    from public.branches b join public.restaurants r on r.id = b.restaurant_id
    left join public.branch_settings bs on bs.branch_id = b.id where b.id = p_branch;
$$;

create or replace function app.try_auto_close_day(p_day uuid) returns boolean
language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.business_days; v_z jsonb;
begin
  select * into d from public.business_days where id = p_day and status = 'open' for update;
  if not found then return false; end if;
  if exists (select 1 from public.business_days where branch_id = d.branch_id and status = 'parked') then return false; end if;
  if exists (select 1 from public.orders where branch_id = d.branch_id and business_date = d.business_date and status = 'completed'
               and payment_status in ('unpaid', 'partial') and merged_into is null) then return false; end if;
  perform app.close_auto_shifts(d.branch_id, null);
  if exists (select 1 from public.shifts where branch_id = d.branch_id and status = 'open') then return false; end if;
  update public.business_days set status = 'closed', closed_at = now(), closed_by = null,
         close_notes = 'Closed automatically at the day cutoff' where id = d.id;
  v_z := app.z_report(d.id);
  update public.business_days set z_report = v_z where id = d.id;
  insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, actor_type, new_value)
  values (d.restaurant_id, d.branch_id, null, 'day.close', 'business_days', d.id, 'system',
          jsonb_build_object('business_date', d.business_date, 'total_billed', v_z->'total_billed', 'bills', v_z->'bills', 'automatic', true));
  return true;
end $$;

create or replace function app.open_business_day(p_branch uuid) returns public.business_days
language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.business_days; v_rest uuid; v_date date; v_today date;
begin
  v_today := app.business_today(p_branch);
  select * into d from public.business_days where branch_id = p_branch and status = 'open';
  if found then
    if d.business_date >= v_today or not app.try_auto_close_day(d.id) then return d; end if;
  end if;
  select b.restaurant_id into v_rest from public.branches b where b.id = p_branch;
  if v_rest is null then raise exception 'Branch not found.'; end if;
  perform pg_advisory_xact_lock(hashtext('business_day:' || p_branch::text));
  select * into d from public.business_days where branch_id = p_branch and status = 'open';
  if found then return d; end if;
  select greatest(v_today, coalesce(max(business_date) + 1, v_today)) into v_date from public.business_days where branch_id = p_branch;
  insert into public.business_days (restaurant_id, branch_id, business_date) values (v_rest, p_branch, v_date)
  returning * into d;
  return d;
end $$;

create table if not exists public.meal_sessions (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id),
  branch_id uuid references public.branches(id),
  name text not null check (length(name) between 1 and 30),
  start_time time not null,
  end_time time not null,
  days smallint[] not null default '{1,2,3,4,5,6,7}',
  display_order int not null default 0,
  created_at timestamptz not null default now(),
  check (start_time <> end_time)
);
create index if not exists meal_sessions_rest_idx on public.meal_sessions (restaurant_id, branch_id);
alter table public.meal_sessions enable row level security;
drop policy if exists tenant_read on public.meal_sessions;
create policy tenant_read on public.meal_sessions for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
revoke all on public.meal_sessions from anon;
revoke insert, update, delete on public.meal_sessions from authenticated;
grant select on public.meal_sessions to authenticated;

alter table public.orders add column if not exists session_id uuid references public.meal_sessions(id) on delete set null;
alter table public.orders add column if not exists session_name text;

create or replace function app.session_at(p_branch uuid, p_at timestamptz) returns public.meal_sessions
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_local timestamp; t time; wd int; s public.meal_sessions; v_rest uuid; v_own boolean;
begin
  select b.restaurant_id, p_at at time zone coalesce(b.timezone, r.timezone, 'UTC') into v_rest, v_local
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = p_branch;
  t := v_local::time; wd := extract(isodow from v_local)::int;
  v_own := exists (select 1 from public.meal_sessions where branch_id = p_branch);
  select * into s from public.meal_sessions m
   where m.restaurant_id = v_rest and (case when v_own then m.branch_id = p_branch else m.branch_id is null end)
     and ((m.start_time < m.end_time and t >= m.start_time and t < m.end_time and wd = any(m.days))
       or (m.start_time > m.end_time and t >= m.start_time and wd = any(m.days))
       or (m.start_time > m.end_time and t < m.end_time and ((wd + 5) % 7 + 1) = any(m.days)))
   order by m.display_order limit 1;
  return s;
end $$;

create or replace function app.set_order_session() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.meal_sessions;
begin
  if new.session_name is null then
    s := app.session_at(new.branch_id, coalesce(new.client_created_at, now()));
    new.session_id := s.id; new.session_name := s.name;
  end if;
  return new;
end $$;
drop trigger if exists trg_order_session on public.orders;
create trigger trg_order_session before insert on public.orders for each row execute function app.set_order_session();

create or replace function public.save_meal_sessions(p_branch uuid, p_sessions jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); a jsonb; b jsonb; i int; j int; n int;
  sa int; ea int; sb int; eb int; da int[]; db int[];
begin
  perform app.require_permission('settings.manage');
  if p_branch is not null and not exists (select 1 from public.branches where id = p_branch and restaurant_id = v_rest) then
    raise exception 'Outlet not found.';
  end if;
  if jsonb_typeof(p_sessions) <> 'array' then raise exception 'Send a list of sessions.'; end if;
  n := jsonb_array_length(p_sessions);
  if n > 12 then raise exception 'At most 12 sessions.'; end if;
  for i in 0 .. n - 1 loop
    a := p_sessions->i;
    if coalesce(trim(a->>'name'), '') = '' then raise exception 'Every session needs a name.'; end if;
    if (a->>'start')::time = (a->>'end')::time then raise exception '% starts and ends at the same time.', a->>'name'; end if;
    for j in i + 1 .. n - 1 loop
      b := p_sessions->j;
      da := coalesce((select array_agg(x::int) from jsonb_array_elements_text(a->'days') x), '{1,2,3,4,5,6,7}');
      db := coalesce((select array_agg(x::int) from jsonb_array_elements_text(b->'days') x), '{1,2,3,4,5,6,7}');
      if not (da && db) then continue; end if;
      sa := extract(epoch from (a->>'start')::time) / 60; ea := extract(epoch from (a->>'end')::time) / 60;
      sb := extract(epoch from (b->>'start')::time) / 60; eb := extract(epoch from (b->>'end')::time) / 60;
      if ea <= sa then ea := ea + 1440; end if;
      if eb <= sb then eb := eb + 1440; end if;
      if (sa < eb and sb < ea) or (sa + 1440 < eb and sb < ea + 1440) or (sb + 1440 < ea and sa < eb + 1440) then
        raise exception '% and % overlap. Sessions must not overlap.', a->>'name', b->>'name';
      end if;
    end loop;
  end loop;
  delete from public.meal_sessions where restaurant_id = v_rest and branch_id is not distinct from p_branch;
  insert into public.meal_sessions (restaurant_id, branch_id, name, start_time, end_time, days, display_order)
  select v_rest, p_branch, left(trim(x->>'name'), 30), (x->>'start')::time, (x->>'end')::time,
         coalesce((select array_agg(d::smallint) from jsonb_array_elements_text(x->'days') d), '{1,2,3,4,5,6,7}'), o::int
    from jsonb_array_elements(p_sessions) with ordinality as t(x, o);
  perform app.audit('settings.sessions', 'meal_sessions', null, jsonb_build_object('branch', p_branch, 'sessions', p_sessions), null);
end $$;

create or replace function public.save_day_settings(p_shifts_enabled boolean, p_cutoff time) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('settings.manage');
  if p_cutoff < '00:00' or p_cutoff > '08:00' then raise exception 'The day cutoff must be between midnight and 8 a.m.'; end if;
  update public.branch_settings set shifts_enabled = p_shifts_enabled, day_cutoff = p_cutoff, updated_at = now()
   where restaurant_id = app.current_restaurant_id();
  perform app.audit('settings.day', 'branch_settings', null, jsonb_build_object('shifts_enabled', p_shifts_enabled, 'day_cutoff', p_cutoff), null);
end $$;

create or replace function public.session_report(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_permission('report.view_sales');
  if p_to < p_from or p_to - p_from > 366 then raise exception 'Choose up to one year.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('session', sn, 'bills', c, 'total', t, 'average', round(t / nullif(c, 0), 2),
             'top_items', (select coalesce(jsonb_agg(jsonb_build_object('item', it, 'qty', q) order by q desc), '[]'::jsonb) from (
                 select i.product_name it, sum(i.quantity) q from public.order_items i join public.orders o2 on o2.id = i.order_id
                  where o2.branch_id = app.current_branch_id() and o2.business_date between p_from and p_to and o2.status = 'completed'
                    and o2.merged_into is null and coalesce(o2.session_name, 'Other') = sn and i.cancelled_at is null
                  group by 1 order by 2 desc limit 5) ti))
           order by first_t)
      from (select coalesce(o.session_name, 'Other') sn, count(*) c, sum(o.grand_total) t,
                   min(coalesce(ms.display_order, 99)) first_t
              from public.orders o left join public.meal_sessions ms on ms.id = o.session_id
             where o.branch_id = app.current_branch_id() and o.business_date between p_from and p_to
               and o.status = 'completed' and o.merged_into is null
             group by 1) s), '[]'::jsonb);
end $$;

create or replace function app.seed_sessions(p_rest uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_country text;
begin
  if exists (select 1 from public.meal_sessions where restaurant_id = p_rest) then return; end if;
  select country_code into v_country from public.restaurants where id = p_rest;
  if v_country = 'IN' then
    insert into public.meal_sessions (restaurant_id, name, start_time, end_time, display_order) values
      (p_rest, 'Breakfast', '06:00', '11:00', 1), (p_rest, 'Lunch', '11:00', '15:00', 2), (p_rest, 'Hi-Tea', '15:00', '17:00', 3),
      (p_rest, 'Evening snacks', '17:00', '19:00', 4), (p_rest, 'Dinner', '19:00', '04:00', 5);
  else
    insert into public.meal_sessions (restaurant_id, name, start_time, end_time, display_order) values
      (p_rest, 'Breakfast', '06:00', '11:00', 1), (p_rest, 'Lunch', '11:00', '15:00', 2), (p_rest, 'Afternoon', '15:00', '18:00', 3),
      (p_rest, 'Dinner', '18:00', '04:00', 4);
  end if;
end $$;
create or replace function app.seed_sessions_trigger() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin perform app.seed_sessions(new.id); return new; end $$;
drop trigger if exists trg_seed_sessions on public.restaurants;
create trigger trg_seed_sessions after insert on public.restaurants for each row execute function app.seed_sessions_trigger();
select app.seed_sessions(id) from public.restaurants;

revoke all on function public.save_meal_sessions(uuid, jsonb), public.save_day_settings(boolean, time), public.session_report(date, date) from public, anon;
grant execute on function public.save_meal_sessions(uuid, jsonb), public.save_day_settings(boolean, time), public.session_report(date, date) to authenticated;
revoke all on function app.auto_shift(uuid), app.close_auto_shifts(uuid, numeric), app.try_auto_close_day(uuid), app.session_at(uuid, timestamptz),
  app.seed_sessions(uuid), app.business_today(uuid) from public, anon, authenticated;
