-- 081: the day's figures sent on a schedule
--
-- An owner chooses a time of day, the days of the week, and who gets it:
-- up to 5 email addresses and/or a phone alert in the owner app. A timer in
-- the database (see 082) looks every 5 minutes for schedules that are due.
--
-- The email itself is sent by the app (/api/report-email), which the database
-- calls with the shared secret -- the same way phone alerts already work.
-- Every write goes through the functions below; nobody reads or writes the
-- tables directly.

create table if not exists public.report_schedules (
  id                uuid primary key default gen_random_uuid(),
  restaurant_id     uuid not null references public.restaurants(id) on delete cascade,
  branch_id         uuid not null,
  send_time         time not null,
  days              smallint[] not null default '{1,2,3,4,5,6,7}',   -- 1 = Monday ... 7 = Sunday
  emails            text[] not null default '{}',
  phone_alert       boolean not null default false,
  is_active         boolean not null default true,
  last_run_on       date,          -- the calendar day (outlet's clock) whose send has been dealt with
  last_sent_at      timestamptz,
  last_for_date     date,          -- the business day the last summary was about
  last_result       text,
  last_email_result text,          -- what the app reported back about the email
  last_problem      text,          -- why a send did not happen (missed, limit reached, error)
  last_problem_at   timestamptz,
  created_by        uuid references public.users(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (restaurant_id, branch_id) references public.branches (restaurant_id, id) on delete cascade,
  constraint report_schedules_days_check check (cardinality(days) between 1 and 7 and days <@ '{1,2,3,4,5,6,7}'::smallint[]),
  constraint report_schedules_emails_check check (cardinality(emails) <= 5),
  constraint report_schedules_someone_check check (cardinality(emails) > 0 or phone_alert)
);
create index if not exists report_schedules_branch on public.report_schedules (branch_id);
create index if not exists report_schedules_due on public.report_schedules (send_time) where is_active;
alter table public.report_schedules enable row level security;
revoke all on public.report_schedules from anon, authenticated;
comment on table public.report_schedules is
  'When the daily summary is sent and to whom. Written and read only by the database functions.';

-- How much has been sent in a day. Kept apart from the schedules, so removing
-- a schedule and adding it again does not start the count from zero.
create table if not exists public.report_send_days (
  scope  text not null,           -- 'b:<outlet id>', 'r:<restaurant id>', or 'all' (the whole system)
  day    date not null,
  sends  int not null default 0,  -- scheduled summaries
  tests  int not null default 0,  -- "send a test now"
  emails int not null default 0,  -- email addresses written to
  primary key (scope, day)
);
alter table public.report_send_days enable row level security;
revoke all on public.report_send_days from anon, authenticated;
comment on table public.report_send_days is
  'Daily counts behind the sending limits for scheduled summaries. Written and read only by the database functions.';

create or replace function app.report_count(p_scope text, p_day date, p_sends int, p_tests int, p_emails int)
returns void
language sql
security definer
set search_path to 'public', 'pg_temp'
as $$
  insert into public.report_send_days (scope, day, sends, tests, emails)
  values (p_scope, p_day, p_sends, p_tests, p_emails)
  on conflict (scope, day) do update
    set sends = public.report_send_days.sends + excluded.sends,
        tests = public.report_send_days.tests + excluded.tests,
        emails = public.report_send_days.emails + excluded.emails;
$$;
revoke all on function app.report_count(text, date, int, int, int) from public, anon, authenticated;

------------------------------------------------------------------
-- Which business day a send at this time of day is about
------------------------------------------------------------------
-- A send in the 12 hours after the day ends (a morning send) is about the day
-- that has just ended: 1. Any later send is about the day still running: 0.
create or replace function app.report_day_back(p_branch uuid, p_time time)
returns int
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
  select case when mod(extract(epoch from p_time)::int
                       - extract(epoch from coalesce(bs.day_cutoff, '04:00'::time))::int + 86400, 86400) < 43200
              then 1 else 0 end
    from public.branches b
    left join public.branch_settings bs on bs.branch_id = b.id
   where b.id = p_branch;
$$;
revoke all on function app.report_day_back(uuid, time) from public, anon, authenticated;

-- The day a send that was due at p_due (outlet's clock) is about.
--
-- Bills are dated by the day that is open, not by the calendar: a day stays
-- open past its end while a bill is unpaid, a shift is open or a day is
-- parked. When that has happened the open day holds every bill made since,
-- so that is the day to report -- not an empty calendar day.
create or replace function app.report_target(p_branch uuid, p_time time, p_due timestamp, out o_date date, out o_lagging boolean)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_cut time; v_wanted date; d record;
begin
  select coalesce(bs.day_cutoff, '04:00'::time) into v_cut
    from public.branches b left join public.branch_settings bs on bs.branch_id = b.id where b.id = p_branch;
  v_wanted := (p_due - coalesce(v_cut, '04:00'::time)::interval)::date - app.report_day_back(p_branch, p_time);
  o_date := v_wanted; o_lagging := false;
  select business_date, status into d from public.business_days
   where branch_id = p_branch and business_date <= v_wanted
   order by business_date desc limit 1;
  if found and d.business_date < v_wanted and d.status <> 'closed' then
    o_date := d.business_date; o_lagging := true;
  end if;
end $$;
revoke all on function app.report_target(uuid, time, timestamp) from public, anon, authenticated;

------------------------------------------------------------------
-- The figures
------------------------------------------------------------------
create or replace function app.report_summary(p_branch uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  b public.branches%rowtype; r public.restaurants%rowtype; d public.business_days%rowtype;
  z jsonb := '{}'::jsonb; v_items jsonb; v_outlets int;
begin
  select * into b from public.branches where id = p_branch;
  if not found then return null; end if;
  select * into r from public.restaurants where id = b.restaurant_id;
  select count(*) into v_outlets from public.branches where restaurant_id = b.restaurant_id and deleted_at is null;

  select * into d from public.business_days where branch_id = p_branch and business_date = p_date;
  if found then
    -- A closed day keeps the report saved when it closed, exactly as the Day report screen shows it.
    z := case when d.status = 'closed' and d.z_report is not null then d.z_report else app.z_report(d.id) end;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('item', x.name, 'qty', x.q, 'amount', x.a) order by x.a desc, x.name), '[]'::jsonb)
    into v_items
    from (select oi.product_name as name, sum(oi.quantity) as q, sum(oi.line_subtotal) as a
            from public.order_items oi
            join public.orders o on o.id = oi.order_id
            left join public.products p on p.id = oi.product_id
           where o.branch_id = p_branch and o.business_date = p_date and o.status = 'completed'
             and o.merged_into is null and oi.cancelled_at is null and not coalesce(p.is_charge, false)
           group by oi.product_name
           order by 3 desc, 1
           limit 5) x;

  return jsonb_build_object(
    'restaurant', r.trading_name, 'outlet', b.name, 'several_outlets', v_outlets > 1,
    'currency', r.currency_code, 'business_date', p_date,
    'day_status', coalesce(d.status, 'none'),
    'bills', coalesce((z->>'bills')::int, 0),
    'total_billed', coalesce((z->>'total_billed')::numeric, 0),
    'discounts', coalesce((z->>'discounts')::numeric, 0),
    'tax', coalesce((z->>'tax')::numeric, 0),
    'service_charge', coalesce((z->>'service_charge')::numeric, 0),
    'voided_bills', coalesce((z->>'voided_bills')::int, 0),
    'voided_value', coalesce((z->>'voided_value')::numeric, 0),
    'unpaid_bills', coalesce((z->>'unpaid_bills')::int, 0),
    'unpaid_amount', coalesce((z->>'unpaid_amount')::numeric, 0),
    'refunds', coalesce((z->'credit_notes'->>'amount')::numeric, 0),
    'refund_count', coalesce((z->'credit_notes'->>'count')::int, 0),
    'payments', coalesce(z->'payments', '[]'::jsonb),
    'by_type', coalesce(z->'by_type', '[]'::jsonb),
    'top_items', v_items);
end $$;
revoke all on function app.report_summary(uuid, date) from public, anon, authenticated;

------------------------------------------------------------------
-- Send one schedule's summary. p_due: when it was due, on the outlet's clock.
------------------------------------------------------------------
create or replace function app.send_report(p_schedule uuid, p_test boolean, p_due timestamp)
returns text
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  s public.report_schedules%rowtype;
  v_date date; v_lag boolean; v_sum jsonb; v_url text; v_secret text; v_mail_url text;
  v_parts text[] := '{}'; v_text text; v_cur text; v_n int; v_utc date := (now() at time zone 'utc')::date;
begin
  select * into s from public.report_schedules where id = p_schedule;
  if not found then return null; end if;
  select o_date, o_lagging into v_date, v_lag from app.report_target(s.branch_id, s.send_time, p_due);
  v_sum := app.report_summary(s.branch_id, v_date);
  if v_sum is null then return null; end if;
  -- lagging: an older day that is still open and so holds every bill made since.
  -- ended: the day's own end time has passed, so nothing more is expected on it.
  v_sum := v_sum || jsonb_build_object('lagging', coalesce(v_lag, false), 'ended', v_date < app.business_today(s.branch_id));
  v_cur := v_sum->>'currency';

  if s.phone_alert and app.feature_on(s.restaurant_id, 'owner_app') then
    -- An owner alert: it shows in the owner app and goes to the phones that turned alerts on.
    insert into public.owner_alerts (restaurant_id, branch_id, kind, title, body)
    values (s.restaurant_id, s.branch_id, 'report.daily',
            case when p_test then 'Daily summary (test)' else 'Daily summary' end,
            left(concat(to_char(v_date, 'FMDD Mon'), ': ', v_sum->>'bills', ' bills, ', v_cur, ' ', v_sum->>'total_billed', ' billed',
                        case when (v_sum->>'unpaid_amount')::numeric > 0
                             then concat(', ', v_cur, ' ', v_sum->>'unpaid_amount', ' not yet paid') else '' end,
                        case when (v_sum->>'several_outlets')::boolean then concat(' · ', v_sum->>'outlet') else '' end), 300));
    v_parts := v_parts || 'phone alert sent'::text;
  end if;

  v_n := cardinality(s.emails);
  if v_n > 0 then
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_url';
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_secret';
    -- The app's address is stored once, for phone alerts; the email sender lives beside it.
    v_mail_url := regexp_replace(coalesce(v_url, ''), '/api/push/?$', '/api/report-email');
    if v_url is null or v_secret is null or v_mail_url = coalesce(v_url, '') then
      v_parts := v_parts || 'email could not be sent: sending is not set up yet'::text;
    elsif coalesce((select emails from public.report_send_days where scope = 'all' and day = v_utc), 0) + v_n > 500 then
      -- A ceiling for the whole system, so a fault or misuse cannot send without end.
      v_parts := v_parts || 'email could not be sent: the system has reached its limit for today'::text;
    else
      perform net.http_post(url := v_mail_url,
        body := jsonb_build_object('schedule_id', s.id, 'test', coalesce(p_test, false), 'to', to_jsonb(s.emails), 'summary', v_sum),
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
        timeout_milliseconds := 20000);
      perform app.report_count('all', v_utc, 0, 0, v_n);
      v_parts := v_parts || concat('email on its way to ', v_n, case when v_n = 1 then ' address' else ' addresses' end);
    end if;
  end if;

  if cardinality(v_parts) = 0 then v_parts := v_parts || 'nothing was sent: the phone alert needs the Owner mobile app module'::text; end if;
  v_text := array_to_string(v_parts, '; ');
  v_text := upper(left(v_text, 1)) || substr(v_text, 2) || '.';
  update public.report_schedules
     set last_sent_at = now(), last_for_date = v_date, last_result = left(v_text, 200), last_email_result = null,
         last_problem = null, last_problem_at = null
   where id = s.id;
  return v_text;
end $$;
revoke all on function app.send_report(uuid, boolean, timestamp) from public, anon, authenticated;

------------------------------------------------------------------
-- The timer calls this every 5 minutes
------------------------------------------------------------------
create or replace function app.run_report_schedules()
returns int
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  s record; v_local timestamp; v_occ timestamp; v_day date; n int := 0;
begin
  for s in
    select rs.id, rs.branch_id, rs.send_time, rs.days, rs.last_run_on, coalesce(b.timezone, r.timezone, 'UTC') as tz
      from public.report_schedules rs
      join public.branches b on b.id = rs.branch_id
      join public.restaurants r on r.id = rs.restaurant_id
     where rs.is_active and b.deleted_at is null and b.is_active and r.deleted_at is null
       and r.subscription_status not in ('suspended', 'cancelled')
  loop
    v_day := null;
    begin
      v_local := now() at time zone s.tz;
      -- The most recent moment this schedule was due: today at its time, or yesterday's if today's is still to come.
      v_occ := v_local::date + s.send_time;
      if v_occ > v_local then v_occ := v_occ - interval '1 day'; end if;
      v_day := v_occ::date;
      continue when s.last_run_on is not null and s.last_run_on >= v_day;
      continue when not (extract(isodow from v_occ)::smallint = any (s.days));
      -- Claim it first, so two runs of the timer can never both send. The row stays locked until this run ends.
      update public.report_schedules set last_run_on = v_day
       where id = s.id and (last_run_on is null or last_run_on < v_day);
      continue when not found;
      if v_local - v_occ > interval '3 hours' then
        -- The system was not running at the time. A summary that arrives hours late is worse than none.
        update public.report_schedules
           set last_problem = 'Not sent: the system was not running at the set time.', last_problem_at = now() where id = s.id;
        continue;
      end if;
      -- An outlet has 5 schedules at most, each once a day. More than that in a day is not normal use.
      if coalesce((select sends from public.report_send_days where scope = 'b:' || s.branch_id and day = v_day), 0) >= 6 then
        update public.report_schedules
           set last_problem = 'Not sent: this outlet has already sent 6 scheduled summaries today, which is the most allowed.', last_problem_at = now()
         where id = s.id;
        continue;
      end if;
      perform app.send_report(s.id, false, v_occ);
      perform app.report_count('b:' || s.branch_id, v_day, 1, 0, 0);
      n := n + 1;
    exception when others then
      -- One bad schedule must not stop the others, and must not be tried again every 5 minutes:
      -- everything above was undone by the error, so mark the day as dealt with here.
      raise warning 'report schedule % could not be sent: %', s.id, sqlerrm;
      update public.report_schedules
         set last_problem = 'Not sent: something went wrong on our side. It will be tried again at the next set time.',
             last_problem_at = now(), last_run_on = coalesce(v_day, last_run_on)
       where id = s.id;
    end;
  end loop;
  -- The counts are only needed for the day they belong to.
  delete from public.report_send_days where day < current_date - 60;
  return n;
end $$;
revoke all on function app.run_report_schedules() from public, anon, authenticated;

------------------------------------------------------------------
-- What the Settings screen uses
------------------------------------------------------------------
create or replace function public.report_schedules_list()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_branch uuid; v_rest uuid; v_cut time; v_tz text;
begin
  perform app.require_permission('settings.manage');
  perform app.require_permission('report.view_sales');
  v_rest := app.current_restaurant_id();
  v_branch := app.current_branch_id();
  select coalesce(bs.day_cutoff, '04:00'::time), coalesce(b.timezone, r.timezone, 'UTC') into v_cut, v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id
    left join public.branch_settings bs on bs.branch_id = b.id
   where b.id = v_branch;
  return jsonb_build_object(
    'cutoff', to_char(coalesce(v_cut, '04:00'::time), 'HH24:MI'),
    'timezone', v_tz,
    'phone_alert_available', app.feature_on(v_rest, 'owner_app'),
    'schedules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', rs.id, 'time', to_char(rs.send_time, 'HH24:MI'), 'days', to_jsonb(rs.days),
               'emails', to_jsonb(rs.emails), 'phone_alert', rs.phone_alert, 'active', rs.is_active,
               'last_sent_at', rs.last_sent_at, 'last_for_date', rs.last_for_date,
               'last_result', rs.last_result, 'last_email_result', rs.last_email_result,
               'last_problem', rs.last_problem, 'last_problem_at', rs.last_problem_at)
             order by rs.send_time, rs.created_at)
        from public.report_schedules rs
       where rs.restaurant_id = v_rest and rs.branch_id = v_branch), '[]'::jsonb));
end $$;
revoke all on function public.report_schedules_list() from public, anon;
grant execute on function public.report_schedules_list() to authenticated, service_role;

create or replace function public.save_report_schedule(p_id uuid, p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('settings.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  v_time time; v_days smallint[]; v_emails text[] := '{}'; v_phone boolean; v_active boolean;
  v_tz text; v_local timestamp; v_handled date; e text; v_id uuid; v_old jsonb;
  o public.report_schedules%rowtype;
begin
  perform app.require_permission('report.view_sales');
  if v_rest is null or v_branch is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'Nothing to save.'; end if;

  if coalesce(p->>'time', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Choose the time to send the summary.';
  end if;
  v_time := (p->>'time')::time;

  if jsonb_typeof(p->'days') = 'array' then
    select array_agg(distinct x::smallint order by x::smallint) into v_days
      from jsonb_array_elements_text(p->'days') x where x ~ '^[1-7]$';
  end if;
  if v_days is null or cardinality(v_days) = 0 then raise exception 'Choose at least one day of the week.'; end if;

  if jsonb_typeof(p->'emails') = 'array' then
    if jsonb_array_length(p->'emails') > 20 then raise exception 'A schedule can go to 5 email addresses at most.'; end if;
    for e in select distinct lower(trim(x)) from jsonb_array_elements_text(p->'emails') x where trim(x) <> '' order by 1 loop
      if length(e) > 254 or e !~ '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$' then
        raise exception '"%" does not look like an email address.', left(e, 80);
      end if;
      v_emails := v_emails || e;
    end loop;
  end if;
  if cardinality(v_emails) > 5 then
    raise exception 'A schedule can go to 5 email addresses at most. Add another schedule for more.';
  end if;

  v_phone := coalesce(p->>'phone_alert', '') = 'true';
  v_active := coalesce(p->>'active', 'true') <> 'false';

  -- A time that has already passed today starts tomorrow: saving never sends by itself.
  select coalesce(b.timezone, r.timezone, 'UTC') into v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = v_branch;
  v_local := now() at time zone v_tz;
  v_handled := case when v_local::time >= v_time then v_local::date else v_local::date - 1 end;

  if p_id is null then
    if v_phone then perform app.require_feature('owner_app'); end if;
    if cardinality(v_emails) = 0 and not v_phone then
      raise exception 'Add at least one email address, or tick the phone alert.';
    end if;
    -- One at a time per outlet, so two saves at the same moment cannot both slip under the limit.
    perform pg_advisory_xact_lock(hashtext('report_schedules:' || v_branch::text));
    if (select count(*) from public.report_schedules where branch_id = v_branch) >= 5 then
      raise exception 'This outlet already has 5 schedules. Change or remove one.';
    end if;
    insert into public.report_schedules (restaurant_id, branch_id, send_time, days, emails, phone_alert, is_active, last_run_on, created_by)
    values (v_rest, v_branch, v_time, v_days, v_emails, v_phone, v_active, v_handled, v_user)
    returning id into v_id;
  else
    select * into o from public.report_schedules
     where id = p_id and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'That schedule is not here any more. Refresh the page.'; end if;
    -- Ticking the phone alert needs the module; a schedule that already has it may still be changed.
    if v_phone and not o.phone_alert then perform app.require_feature('owner_app'); end if;
    if cardinality(v_emails) = 0 and not v_phone then
      raise exception 'Add at least one email address, or tick the phone alert.';
    end if;
    v_old := jsonb_build_object('time', to_char(o.send_time, 'HH24:MI'), 'days', to_jsonb(o.days), 'emails', to_jsonb(o.emails),
                                'phone_alert', o.phone_alert, 'active', o.is_active);
    update public.report_schedules
       set send_time = v_time, days = v_days, emails = v_emails, phone_alert = v_phone, is_active = v_active,
           -- Changing who gets it leaves today's send alone. A new time, or switching it back on, counts from
           -- now -- and a schedule that has already sent today never sends a second time today.
           last_run_on = case when o.send_time is distinct from v_time or (v_active and not o.is_active)
                              then greatest(coalesce(o.last_run_on, v_handled), v_handled)
                              else o.last_run_on end,
           updated_at = now()
     where id = p_id;
    v_id := p_id;
  end if;

  perform app.audit('report_schedule.save', 'report_schedules', v_id,
    jsonb_build_object('time', to_char(v_time, 'HH24:MI'), 'days', to_jsonb(v_days), 'emails', to_jsonb(v_emails),
                       'phone_alert', v_phone, 'active', v_active),
    v_old);
  return jsonb_build_object('id', v_id);
end $$;
revoke all on function public.save_report_schedule(uuid, jsonb) from public, anon;
grant execute on function public.save_report_schedule(uuid, jsonb) to authenticated, service_role;

-- Switch one schedule on or off without touching anything else on it.
create or replace function public.set_report_schedule_active(p_id uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare o public.report_schedules%rowtype; v_tz text; v_local timestamp; v_handled date; v_on boolean := coalesce(p_on, false);
begin
  perform app.require_permission('settings.manage');
  perform app.require_permission('report.view_sales');
  select * into o from public.report_schedules
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'That schedule is not here any more. Refresh the page.'; end if;
  if o.is_active = v_on then return; end if;
  select coalesce(b.timezone, r.timezone, 'UTC') into v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = o.branch_id;
  v_local := now() at time zone v_tz;
  v_handled := case when v_local::time >= o.send_time then v_local::date else v_local::date - 1 end;
  update public.report_schedules
     set is_active = v_on,
         -- Switched back on after its time has passed today: the next send is tomorrow's.
         last_run_on = case when v_on then greatest(coalesce(o.last_run_on, v_handled), v_handled) else o.last_run_on end,
         updated_at = now()
   where id = o.id;
  perform app.audit('report_schedule.switch', 'report_schedules', o.id, jsonb_build_object('active', v_on), jsonb_build_object('active', o.is_active));
end $$;
revoke all on function public.set_report_schedule_active(uuid, boolean) from public, anon;
grant execute on function public.set_report_schedule_active(uuid, boolean) to authenticated, service_role;

create or replace function public.remove_report_schedule(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_old jsonb;
begin
  perform app.require_permission('settings.manage');
  perform app.require_permission('report.view_sales');
  delete from public.report_schedules
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id()
  returning jsonb_build_object('time', to_char(send_time, 'HH24:MI'), 'emails', to_jsonb(emails), 'phone_alert', phone_alert) into v_old;
  if not found then return; end if;
  perform app.audit('report_schedule.remove', 'report_schedules', p_id, null, v_old);
end $$;
revoke all on function public.remove_report_schedule(uuid) from public, anon;
grant execute on function public.remove_report_schedule(uuid) to authenticated, service_role;

-- "Send a test now": the same summary, straight away, a few times a day at most.
create or replace function public.send_report_now(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  s public.report_schedules%rowtype; v_tz text; v_local timestamp; v_text text;
begin
  perform app.require_permission('settings.manage');
  perform app.require_permission('report.view_sales');
  select * into s from public.report_schedules
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'That schedule is not here any more. Refresh the page.'; end if;
  select coalesce(b.timezone, r.timezone, 'UTC') into v_tz
    from public.branches b join public.restaurants r on r.id = b.restaurant_id where b.id = s.branch_id;
  v_local := now() at time zone v_tz;
  if s.last_sent_at is not null and now() - s.last_sent_at < interval '30 seconds' then
    raise exception 'One was sent a moment ago. Wait half a minute and try again.';
  end if;
  -- Counted for the restaurant, not on the schedule: removing a schedule does not give more tests.
  perform pg_advisory_xact_lock(hashtext('report_tests:' || s.restaurant_id::text));
  if coalesce((select tests from public.report_send_days where scope = 'r:' || s.restaurant_id and day = v_local::date), 0) >= 5 then
    raise exception 'You have sent 5 tests today. The next test can be sent tomorrow.';
  end if;
  perform app.report_count('r:' || s.restaurant_id, v_local::date, 0, 1, 0);

  v_text := app.send_report(s.id, true, v_local);
  perform app.audit('report_schedule.test', 'report_schedules', s.id, jsonb_build_object('result', v_text));
  return jsonb_build_object('message', v_text, 'ok', coalesce(v_text, '') !~* '(could not be sent|nothing was sent)');
end $$;
revoke all on function public.send_report_now(uuid) from public, anon;
grant execute on function public.send_report_now(uuid) to authenticated, service_role;

-- The app reports back what happened to the email. Only the app knows the shared secret.
create or replace function public.report_sent(p_secret text, p_schedule uuid, p_ok boolean, p_note text)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v text;
begin
  select decrypted_secret into v from vault.decrypted_secrets where name = 'push_secret';
  if v is null or p_secret is null or p_secret is distinct from v then raise exception 'Not allowed.'; end if;
  update public.report_schedules
     set last_email_result = left(coalesce(nullif(trim(p_note), ''), case when p_ok then 'Email sent.' else 'The email could not be sent.' end), 200),
         last_problem = case when p_ok then last_problem else 'The email was not sent.' end,
         last_problem_at = case when p_ok then last_problem_at else now() end
   where id = p_schedule;
end $$;
revoke all on function public.report_sent(text, uuid, boolean, text) from public;
grant execute on function public.report_sent(text, uuid, boolean, text) to anon, authenticated, service_role;
