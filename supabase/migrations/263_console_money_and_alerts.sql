-- 263: SNA console: prices with history, an "unpaid" list with due dates, a daily alert email for SNA staff.
-- Nothing here changes what a restaurant sees.

begin;

------------------------------------------------------------------
-- 1. Price changes keep the old price
------------------------------------------------------------------
create or replace function public.sna_set_price(p_item text, p_currency text, p_price numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cur text := upper(trim(p_currency)); v_old numeric; v_had boolean;
begin
  perform app.sna_require(array[]::text[]);
  if p_item not in ('basic', 'professional') and not exists (select 1 from public.modules where key = p_item and kind = 'addon') then
    raise exception 'Unknown plan item.';
  end if;
  if p_price is not null and (p_price < 0 or p_price > 1000000) then raise exception 'Enter a sensible price.'; end if;
  select monthly_price, true into v_old, v_had from public.plan_prices where item = p_item and currency_code = v_cur;
  insert into public.plan_prices (item, currency_code, monthly_price) values (p_item, v_cur, p_price)
  on conflict (item, currency_code) do update set monthly_price = excluded.monthly_price;
  -- Only a real change is written, with what it was before.
  if coalesce(v_had, false) = false or v_old is distinct from p_price then
    perform app.log_plan(null, 'price.set', jsonb_build_object('item', p_item, 'currency', v_cur, 'old', v_old, 'price', p_price));
  end if;
end $$;

-- The last 30 price changes, newest first. Admin only, like the prices themselves.
create or replace function public.sna_price_log() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.sna_require(array[]::text[]);
  return coalesce((
    select jsonb_agg(x.j order by x.at desc) from (
      select e.created_at as at,
             jsonb_build_object(
               'at', e.created_at, 'item', e.details->>'item', 'currency', e.details->>'currency',
               'had_old', e.details ? 'old', 'old', e.details->'old', 'price', e.details->'price',
               'by', (select s.full_name from public.sna_staff s where s.id = e.staff_id)) as j
        from public.subscription_events e
       where e.event = 'price.set'
       order by e.created_at desc limit 30) x), '[]'::jsonb);
end $$;

------------------------------------------------------------------
-- 2. Unpaid sales: a due date, and one list across all clients
------------------------------------------------------------------
alter table public.sna_sales add column if not exists due_on date;
create index if not exists sna_sales_unpaid on public.sna_sales (sale_date) where paid_on is null and cancelled_at is null;

-- Set or clear the date a sale should be paid by. Sales and admin only.
create or replace function public.sna_set_sale_due(p_id uuid, p_due date) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.sna_sales%rowtype;
begin
  perform app.sna_require(array['sales']);
  select * into s from public.sna_sales where id = p_id for update;
  if not found then raise exception 'Sale not found.'; end if;
  if s.cancelled_at is not null then raise exception 'This entry was cancelled.'; end if;
  if p_due is not null and p_due < s.sale_date then raise exception 'The due date cannot be before the sale date.'; end if;
  update public.sna_sales set due_on = p_due where id = p_id;
  perform app.log_plan(s.restaurant_id, 'sale.due', jsonb_build_object('sale', p_id, 'due', p_due, 'was', s.due_on));
end $$;

-- Everything not yet paid, across all clients, oldest first, with totals per currency.
create or replace function public.sna_unpaid() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_today date := app.sna_today();
begin
  perform app.sna_require(array['sales', 'implementer', 'support']);
  return jsonb_build_object(
    'today', v_today,
    'totals', coalesce((
      select jsonb_agg(jsonb_build_object('currency', z.c, 'total', z.t, 'count', z.n, 'overdue', z.o) order by z.c) from (
        select s.currency_code as c, sum(s.amount) as t, count(*) as n, count(*) filter (where s.due_on < v_today) as o
          from public.sna_sales s join public.restaurants r on r.id = s.restaurant_id
         where s.paid_on is null and s.cancelled_at is null and s.amount > 0 and r.deleted_at is null
         group by s.currency_code) z), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(y.j order by y.k1, y.k2) from (
        select coalesce(s.due_on, s.sale_date) as k1, s.created_at as k2,
               jsonb_build_object(
                 'id', s.id, 'restaurant_id', r.id, 'trading_name', r.trading_name, 'client_code', r.client_code,
                 'sale_date', s.sale_date, 'kind', s.kind, 'description', s.description, 'amount', s.amount,
                 'currency', s.currency_code, 'invoice_no', s.invoice_no, 'due_on', s.due_on,
                 'days_since', v_today - s.sale_date,
                 'days_overdue', case when s.due_on < v_today then v_today - s.due_on end) as j
          from public.sna_sales s join public.restaurants r on r.id = s.restaurant_id
         where s.paid_on is null and s.cancelled_at is null and s.amount > 0 and r.deleted_at is null
         order by coalesce(s.due_on, s.sale_date), s.created_at
         limit 500) y), '[]'::jsonb));
end $$;

------------------------------------------------------------------
-- 3. Daily alert email to SNA staff
------------------------------------------------------------------
create table if not exists public.sna_alert_log (
  day      date not null,
  staff_id uuid not null references public.sna_staff(id) on delete cascade,
  sent_at  timestamptz not null default now(),
  primary key (day, staff_id)
);
alter table public.sna_alert_log enable row level security;
revoke all on public.sna_alert_log from anon, authenticated;
comment on table public.sna_alert_log is 'One row per SNA person per day the alert email was handed over, so a repeat run never sends it twice.';

-- What each SNA person should hear about today: the clients they look after (clients with nobody assigned go to admins).
create or replace function app.sna_alert_payloads()
returns table(staff_id uuid, email text, full_name text, payload jsonb)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_today date := app.sna_today();
begin
  return query
  with mine as (
    select st.id as sid, st.email as semail, st.full_name as sname, r.id as rid, r.trading_name, r.client_code, r.subscription_status,
           a.licence_expiry, a.next_contact
      from public.sna_staff st
      join public.restaurants r on r.deleted_at is null
      left join public.sna_accounts a on a.restaurant_id = r.id
     where st.is_active and st.email is not null
       and (a.account_manager = st.id or (a.account_manager is null and st.role = 'admin'))
  ), sec as (
    select m.sid, m.semail, m.sname,
      jsonb_build_object('key', 'expired', 'title', 'Licence ended (read-only now)', 'lines', coalesce((
        select jsonb_agg(concat(x.trading_name, ' (', x.client_code, '): ended ', to_char(x.licence_expiry, 'FMDD Mon YYYY'), ', ', v_today - x.licence_expiry, ' days ago') order by x.licence_expiry)
          from mine x where x.sid = m.sid and x.subscription_status <> 'cancelled'
           and x.licence_expiry < v_today and x.licence_expiry >= v_today - 30), '[]'::jsonb)) as expired,
      jsonb_build_object('key', 'expiring', 'title', 'Licence ends within 30 days', 'lines', coalesce((
        select jsonb_agg(concat(x.trading_name, ' (', x.client_code, '): ends ', to_char(x.licence_expiry, 'FMDD Mon YYYY'), case when x.licence_expiry = v_today then ' (today)' else concat(' (', x.licence_expiry - v_today, ' days)') end) order by x.licence_expiry)
          from mine x where x.sid = m.sid and x.subscription_status <> 'cancelled'
           and x.licence_expiry between v_today and v_today + 30), '[]'::jsonb)) as expiring,
      jsonb_build_object('key', 'followup', 'title', 'Follow-up due', 'lines', coalesce((
        select jsonb_agg(concat(x.trading_name, ' (', x.client_code, '): follow-up ', to_char(x.next_contact, 'FMDD Mon YYYY')) order by x.next_contact)
          from mine x where x.sid = m.sid and x.next_contact <= v_today), '[]'::jsonb)) as followup,
      jsonb_build_object('key', 'unpaid', 'title', 'Payment overdue', 'lines', coalesce((
        select jsonb_agg(concat(x.trading_name, ' (', x.client_code, '): ', s.currency_code, ' ', s.amount, ' for ', s.description,
                                case when s.due_on is not null then concat(', due ', to_char(s.due_on, 'FMDD Mon YYYY')) else concat(', sold ', to_char(s.sale_date, 'FMDD Mon YYYY'), ', no due date') end)
                         order by coalesce(s.due_on, s.sale_date))
          from mine x join public.sna_sales s on s.restaurant_id = x.rid
         where x.sid = m.sid and s.paid_on is null and s.cancelled_at is null and s.amount > 0
           and (s.due_on <= v_today or (s.due_on is null and s.sale_date <= v_today - 15))), '[]'::jsonb)) as unpaid
      from (select distinct sid, semail, sname from mine) m
  )
  select s.sid, s.semail::text, s.sname::text,
         jsonb_build_object('today', v_today, 'sections', jsonb_build_array(s.expired, s.expiring, s.followup, s.unpaid))
    from sec s
   where jsonb_array_length(s.expired->'lines') + jsonb_array_length(s.expiring->'lines')
       + jsonb_array_length(s.followup->'lines') + jsonb_array_length(s.unpaid->'lines') > 0;
end $$;

-- The daily timer calls this. p_dry returns what would be sent and sends nothing.
create or replace function app.run_sna_alerts(p_dry boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  r record; v_url text; v_secret text; v_mail text; v_console text; v_n int := 0; v_out jsonb := '[]'::jsonb; v_today date := app.sna_today();
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'push_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_secret';
  v_mail := regexp_replace(coalesce(v_url, ''), '/api/push/?$', '/api/sna-alert-email');
  v_console := regexp_replace(coalesce(v_url, ''), '/api/push/?$', '/sna');
  for r in select * from app.sna_alert_payloads() loop
    if p_dry then
      v_out := v_out || jsonb_build_object('to', r.email, 'payload', r.payload);
      continue;
    end if;
    if exists (select 1 from public.sna_alert_log l where l.day = v_today and l.staff_id = r.staff_id) then continue; end if;
    if v_url is null or v_secret is null or v_mail = coalesce(v_url, '') then continue; end if;
    perform net.http_post(url := v_mail,
      body := jsonb_build_object('to', r.email, 'name', r.full_name, 'payload', r.payload, 'console_url', v_console),
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
      timeout_milliseconds := 20000);
    insert into public.sna_alert_log (day, staff_id) values (v_today, r.staff_id) on conflict do nothing;
    v_n := v_n + 1;
  end loop;
  return case when p_dry then v_out else jsonb_build_object('sent', v_n) end;
end $$;

revoke all on function app.sna_alert_payloads(), app.run_sna_alerts(boolean) from public, anon, authenticated;
revoke all on function public.sna_price_log(), public.sna_set_sale_due(uuid, date), public.sna_unpaid() from public, anon;
grant execute on function public.sna_price_log(), public.sna_set_sale_due(uuid, date), public.sna_unpaid() to authenticated;

-- 09:00 India time, every day.
select cron.schedule('sna-licence-alerts', '30 3 * * *', 'select app.run_sna_alerts()');

commit;
