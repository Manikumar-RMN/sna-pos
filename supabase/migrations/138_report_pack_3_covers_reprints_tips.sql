-- 138: Report pack 3 - cover analysis, reprints, tips; and a fix for the pending KOT / pending bills reports of 129.
--
-- 1. report_covers(p_from, p_to)    guests (covers) and sales per guest, by day / outlet / waiter. Needs report.view_sales;
--                                   money columns are filled only for people who ALSO have report.view_financial (else null + "money": false).
-- 2. report_reprints(p_from, p_to)  bill and KOT reprints written to audit_logs (actions 'bill.reprint' and 'kot.reprint', migration 135). report.view_sales.
-- 3. report_tips(p_from, p_to)      tips from public.order_tips (migration 133), by day / payment mode / waiter / outlet. Needs report.view_sales AND
--                                   report.view_financial. Tips are memo-only: they are not in sales, payments or the day close. Tips on voided bills are left out.
-- 4. CREATE OR REPLACE of report_pending_kot and report_pending_bills (129), return shapes UNCHANGED:
--      * pending KOT: create_order marks every bill 'completed' at once, so the old filter (status open / placed / served) hid nearly every
--        pending KOT. Now any bill that is not voided and not merged counts; a KOT is pending while a line is new / preparing. kot_time =
--        coalesce(client_created_at, created_at) (the time the ticket was really made, also for offline bills).
--      * pending bills: a dine-in bill that is unpaid or partly paid (payment_status unpaid / partial), not voided, not merged, is a running table
--        bill: kind 'open'. Any other unpaid / partly paid bill (takeaway, delivery) stays kind 'unsettled'.
--
-- Same safety and style as 128 / 129: read-only, STABLE, SECURITY DEFINER, search_path = public, pg_temp, own restaurant only, outlet scope from
-- app.report_branch(), business day filters, 366-day limit with the same messages, revoked from public/anon, granted to authenticated.
-- report_tips and report_reprints read tables that other changes create (133, 135); plpgsql only looks the table up when it runs, so this file can be
-- applied before them, but the two reports need 133 / 135 to be applied to return anything.
--
-- Return shapes (jsonb, money as numbers):
--   report_covers   {money, by_day:[{business_date, bills, covers, sales, sales_per_cover}],
--                    by_outlet:[{branch_id, outlet_name, bills, covers, sales, sales_per_cover}],
--                    by_waiter:[{branch_id, outlet_name, user_id, staff_name, bills, covers, sales, sales_per_cover}],
--                    totals:{bills, bills_with_covers, bills_without_covers, covers, sales, sales_per_cover}}
--      dine-in bills, status 'completed' (so never voided), not merged. covers = sum of covers on bills that have covers; sales and sales_per_cover use ONLY
--      the bills that have covers (so bills without guests do not pull the average down); "sales" in totals = sales of those bills. waiter = coalesce(waiter_id, cashier_id).
--   report_reprints {rows:[{id, at, action, kind 'bill'|'kot', user_id, user_name, branch_id, outlet_name, order_id, bill_number, table_number, detail}],
--                    by_user:[{user_id, user_name, bills, kots}], truncated, row_limit, total_rows, totals:{reprints, bills, kots}}
--      detail = the audit row's new_value (jsonb). Newest first, first 2000 rows, totals over all.
--   report_tips     {by_day:[{business_date, tips, amount}], by_method:[{method, kind, tips, amount}],
--                    by_waiter:[{branch_id, outlet_name, user_id, staff_name, tips, amount}], by_outlet:[{branch_id, outlet_name, tips, amount}],
--                    totals:{tips, amount, bills}}      waiter = coalesce(order_tips.waiter_id, order_tips.received_by).
-- Safe to run again (create or replace).

-- ---------------------------------------------------------------- 1. pending KOT (fixed)
create or replace function public.report_pending_kot(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with k as (
      select kt.id as kt_id, kt.ticket_number, kt.station, kt.status as ticket_status, coalesce(kt.client_created_at, kt.created_at) as kot_time,
             o.id as order_id, o.bill_number, o.status as order_status, o.branch_id, o.order_type, o.dining_table_id
        from public.kitchen_tickets kt
        join public.orders o on o.id = kt.order_id
       where kt.restaurant_id = v_rest and o.restaurant_id = v_rest
         and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.status <> 'voided' and o.merged_into is null
         and kt.status <> 'cancelled'
         and exists (select 1 from public.kitchen_ticket_items ki
                       left join public.order_items oi on oi.id = ki.order_item_id
                      where ki.kitchen_ticket_id = kt.id and ki.status in ('new', 'preparing') and oi.cancelled_at is null)),
    r as (
      select jsonb_build_object(
               'kitchen_ticket_id', k.kt_id, 'ticket_number', k.ticket_number, 'station', k.station, 'ticket_status', k.ticket_status,
               'order_id', k.order_id, 'bill_number', k.bill_number, 'order_status', k.order_status,
               'branch_id', k.branch_id, 'outlet_name', coalesce(b.name, 'Unknown outlet'),
               'table_number', dt.table_number, 'order_type', k.order_type,
               'kot_time', k.kot_time,
               'minutes_pending', greatest(0, floor(extract(epoch from (now() - k.kot_time)) / 60))::int,
               'items', (select coalesce(jsonb_agg(jsonb_build_object('name', ki.product_name, 'quantity', ki.quantity, 'status', ki.status, 'note', ki.note)
                                                   order by oi.created_at, ki.product_name, ki.id), '[]'::jsonb)
                           from public.kitchen_ticket_items ki
                           left join public.order_items oi on oi.id = ki.order_item_id
                          where ki.kitchen_ticket_id = k.kt_id and ki.status in ('new', 'preparing') and oi.cancelled_at is null)) as j,
             k.kot_time, k.ticket_number,
             (select count(*) from public.kitchen_ticket_items ki left join public.order_items oi on oi.id = ki.order_item_id
               where ki.kitchen_ticket_id = k.kt_id and ki.status in ('new', 'preparing') and oi.cancelled_at is null) as n_items
        from k
        left join public.branches b on b.id = k.branch_id
        left join public.dining_tables dt on dt.id = k.dining_table_id)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(r.j order by r.kot_time, r.ticket_number) from r), '[]'::jsonb),
      'totals', jsonb_build_object('kots', (select count(*) from r), 'items', coalesce((select sum(r.n_items) from r), 0)))
  );
end $$;

-- ---------------------------------------------------------------- 2. pending bills (fixed)
create or replace function public.report_pending_bills(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with x as (
      select o.id, o.bill_number, o.status, o.payment_status, o.branch_id, o.order_type, o.dining_table_id, o.waiter_id, o.cashier_id,
             o.business_date, o.created_at, o.grand_total as amount,
             app.order_covered(o.id) as paid,
             case when o.status in ('open', 'placed', 'served')
                    or (o.order_type = 'dine_in' and o.payment_status in ('unpaid', 'partial')) then 'open' else 'unsettled' end as kind
        from public.orders o
       where o.restaurant_id = v_rest
         and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.merged_into is null and o.status <> 'voided'
         and (o.status in ('open', 'placed', 'served')
              or o.payment_status in ('unpaid', 'partial'))),
    y as (
      select x.*, x.amount - x.paid as balance from x where x.kind = 'open' or x.amount - x.paid > 0),
    r as (
      select y.*, coalesce(b.name, 'Unknown outlet') as outlet_name, dt.table_number, w.full_name as waiter, c.full_name as cashier
        from y
        left join public.branches b on b.id = y.branch_id
        left join public.dining_tables dt on dt.id = y.dining_table_id
        left join public.users w on w.id = y.waiter_id
        left join public.users c on c.id = y.cashier_id)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                 'kind', r.kind, 'order_id', r.id, 'bill_number', r.bill_number, 'order_status', r.status, 'payment_status', r.payment_status,
                 'branch_id', r.branch_id, 'outlet_name', r.outlet_name, 'table_number', r.table_number, 'order_type', r.order_type,
                 'waiter', r.waiter, 'cashier', r.cashier, 'business_date', r.business_date, 'created_at', r.created_at,
                 'amount', r.amount, 'paid', r.paid, 'balance', r.balance,
                 'age_minutes', greatest(0, floor(extract(epoch from (now() - r.created_at)) / 60))::int)
                 order by r.created_at, r.bill_number) from r), '[]'::jsonb),
      'totals', jsonb_build_object('bills', (select count(*) from r), 'amount', coalesce((select sum(r.amount) from r), 0),
                 'paid', coalesce((select sum(r.paid) from r), 0), 'balance', coalesce((select sum(r.balance) from r), 0)))
  );
end $$;

-- ---------------------------------------------------------------- 5. cover analysis
create or replace function public.report_covers(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_money boolean;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest  := app.current_restaurant_id();
  v_rb    := app.report_branch();
  v_money := app.has_permission('report.view_financial');
  return (
    with o as (
      select ord.id, ord.branch_id, ord.business_date, coalesce(ord.waiter_id, ord.cashier_id) as staff_id,
             greatest(0, trunc(coalesce(ord.covers, 0)))::int as covers, ord.grand_total
        from public.orders ord
       where ord.restaurant_id = v_rest
         and (v_rb is null or ord.branch_id = v_rb)
         and ord.business_date between p_from and p_to
         and ord.order_type = 'dine_in'
         and ord.status = 'completed' and ord.merged_into is null),
    day_ as (
      select o.business_date, count(*) as bills, coalesce(sum(o.covers), 0) as covers,
             coalesce(sum(o.grand_total) filter (where o.covers > 0), 0) as sales
        from o group by o.business_date),
    out_ as (
      select o.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, count(*) as bills, coalesce(sum(o.covers), 0) as covers,
             coalesce(sum(o.grand_total) filter (where o.covers > 0), 0) as sales
        from o left join public.branches b on b.id = o.branch_id group by o.branch_id, b.name),
    wtr as (
      select o.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, o.staff_id, coalesce(u.full_name, 'Unknown') as staff_name,
             count(*) as bills, coalesce(sum(o.covers), 0) as covers, coalesce(sum(o.grand_total) filter (where o.covers > 0), 0) as sales
        from o left join public.branches b on b.id = o.branch_id left join public.users u on u.id = o.staff_id
       group by o.branch_id, b.name, o.staff_id, u.full_name)
    select jsonb_build_object(
      'money', v_money,
      'by_day', coalesce((select jsonb_agg(jsonb_build_object('business_date', d.business_date, 'bills', d.bills, 'covers', d.covers,
                 'sales', case when v_money then d.sales end,
                 'sales_per_cover', case when v_money and d.covers > 0 then round(d.sales / d.covers, 2) end) order by d.business_date) from day_ d), '[]'::jsonb),
      'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', x.branch_id, 'outlet_name', x.outlet_name, 'bills', x.bills, 'covers', x.covers,
                 'sales', case when v_money then x.sales end,
                 'sales_per_cover', case when v_money and x.covers > 0 then round(x.sales / x.covers, 2) end) order by x.outlet_name, x.branch_id) from out_ x), '[]'::jsonb),
      'by_waiter', coalesce((select jsonb_agg(jsonb_build_object('branch_id', w.branch_id, 'outlet_name', w.outlet_name, 'user_id', w.staff_id, 'staff_name', w.staff_name,
                 'bills', w.bills, 'covers', w.covers, 'sales', case when v_money then w.sales end,
                 'sales_per_cover', case when v_money and w.covers > 0 then round(w.sales / w.covers, 2) end)
                 order by w.covers desc, w.outlet_name, w.staff_name, w.staff_id) from wtr w), '[]'::jsonb),
      'totals', jsonb_build_object(
         'bills', (select count(*) from o),
         'bills_with_covers', (select count(*) from o where o.covers > 0),
         'bills_without_covers', (select count(*) from o where o.covers = 0),
         'covers', coalesce((select sum(o.covers) from o), 0),
         'sales', case when v_money then coalesce((select sum(o.grand_total) from o where o.covers > 0), 0) end,
         'sales_per_cover', case when v_money and coalesce((select sum(o.covers) from o), 0) > 0
                                 then round(coalesce((select sum(o.grand_total) from o where o.covers > 0), 0) / (select sum(o.covers) from o), 2) end))
  );
end $$;

-- ---------------------------------------------------------------- 6. reprints
-- Audit rows 'bill.reprint' / 'kot.reprint' (written by log_print, migration 135) whose time falls inside the range in the restaurant's time zone.
create or replace function public.report_reprints(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_tz text; v_start timestamptz; v_end timestamptz;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  select coalesce(nullif(timezone, ''), 'UTC') into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;
  return (
    with a as (
      select al.id, al.created_at, al.action, al.user_id, al.branch_id, al.new_value,
             case when al.entity_type in ('orders', 'order') then al.entity_id end as order_id
        from public.audit_logs al
       where al.restaurant_id = v_rest
         and al.action in ('bill.reprint', 'kot.reprint')
         and (v_rb is null or al.branch_id = v_rb)
         and al.created_at >= v_start and al.created_at < v_end),
    capped as (select * from a order by a.created_at desc, a.id desc limit 2000),
    r as (
      select c.*, u.full_name as user_name, coalesce(b.name, 'Unknown outlet') as outlet_name, o.bill_number, dt.table_number
        from capped c
        left join public.users u on u.id = c.user_id
        left join public.branches b on b.id = c.branch_id
        left join public.orders o on o.id = c.order_id and o.restaurant_id = v_rest
        left join public.dining_tables dt on dt.id = o.dining_table_id)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', r.id, 'at', r.created_at, 'action', r.action, 'kind', case when r.action = 'kot.reprint' then 'kot' else 'bill' end,
                 'user_id', r.user_id, 'user_name', r.user_name, 'branch_id', r.branch_id, 'outlet_name', r.outlet_name,
                 'order_id', r.order_id, 'bill_number', coalesce(r.bill_number, r.new_value ->> 'bill_number'), 'table_number', r.table_number,
                 'detail', r.new_value) order by r.created_at desc, r.id desc) from r), '[]'::jsonb),
      'by_user', coalesce((select jsonb_agg(jsonb_build_object('user_id', g.user_id, 'user_name', coalesce(g.user_name, 'Unknown'), 'bills', g.bills, 'kots', g.kots)
                 order by g.bills + g.kots desc, g.user_name, g.user_id)
                 from (select a.user_id, u.full_name as user_name,
                              count(*) filter (where a.action = 'bill.reprint') as bills, count(*) filter (where a.action = 'kot.reprint') as kots
                         from a left join public.users u on u.id = a.user_id group by a.user_id, u.full_name) g), '[]'::jsonb),
      'truncated', (select count(*) from a) > 2000,
      'row_limit', 2000,
      'total_rows', (select count(*) from a),
      'totals', jsonb_build_object('reprints', (select count(*) from a),
                 'bills', (select count(*) from a where a.action = 'bill.reprint'), 'kots', (select count(*) from a where a.action = 'kot.reprint')))
  );
end $$;

-- ---------------------------------------------------------------- 7. tips
-- Tips are memo-only (order_tips, migration 133). A tip on a voided bill is left out. By the tip's business_date. Needs the financial right.
create or replace function public.report_tips(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_permission('report.view_sales');
  if not app.has_permission('report.view_financial') then raise exception 'You do not have the right to see financial reports.'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with t as (
      select ot.id, ot.order_id, ot.branch_id, ot.business_date, ot.amount, ot.method_id, coalesce(ot.waiter_id, ot.received_by) as staff_id
        from public.order_tips ot
        join public.orders o on o.id = ot.order_id and o.restaurant_id = v_rest
       where ot.restaurant_id = v_rest
         and (v_rb is null or ot.branch_id = v_rb)
         and ot.business_date between p_from and p_to
         and o.status <> 'voided')
    select jsonb_build_object(
      'by_day', coalesce((select jsonb_agg(jsonb_build_object('business_date', g.business_date, 'tips', g.n, 'amount', g.amt) order by g.business_date)
                 from (select t.business_date, count(*) as n, sum(t.amount) as amt from t group by t.business_date) g), '[]'::jsonb),
      'by_method', coalesce((select jsonb_agg(jsonb_build_object('method', g.method, 'kind', g.kind, 'tips', g.n, 'amount', g.amt) order by g.amt desc, g.method)
                 from (select coalesce(pm.name, 'Unspecified') as method, pm.kind, count(*) as n, sum(t.amount) as amt
                         from t left join public.payment_methods pm on pm.id = t.method_id group by pm.name, pm.kind) g), '[]'::jsonb),
      'by_waiter', coalesce((select jsonb_agg(jsonb_build_object('branch_id', g.branch_id, 'outlet_name', g.outlet_name, 'user_id', g.staff_id,
                 'staff_name', g.staff_name, 'tips', g.n, 'amount', g.amt) order by g.amt desc, g.outlet_name, g.staff_name, g.staff_id)
                 from (select t.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, t.staff_id, coalesce(u.full_name, 'Unknown') as staff_name,
                              count(*) as n, sum(t.amount) as amt
                         from t left join public.branches b on b.id = t.branch_id left join public.users u on u.id = t.staff_id
                        group by t.branch_id, b.name, t.staff_id, u.full_name) g), '[]'::jsonb),
      'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', g.branch_id, 'outlet_name', g.outlet_name, 'tips', g.n, 'amount', g.amt)
                 order by g.outlet_name, g.branch_id)
                 from (select t.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, count(*) as n, sum(t.amount) as amt
                         from t left join public.branches b on b.id = t.branch_id group by t.branch_id, b.name) g), '[]'::jsonb),
      'totals', jsonb_build_object('tips', (select count(*) from t), 'amount', coalesce((select sum(t.amount) from t), 0),
                 'bills', (select count(distinct t.order_id) from t)))
  );
end $$;

revoke all on function public.report_pending_kot(date,date), public.report_pending_bills(date,date),
  public.report_covers(date,date), public.report_reprints(date,date), public.report_tips(date,date) from public, anon;
grant execute on function public.report_pending_kot(date,date), public.report_pending_bills(date,date),
  public.report_covers(date,date), public.report_reprints(date,date), public.report_tips(date,date) to authenticated;
