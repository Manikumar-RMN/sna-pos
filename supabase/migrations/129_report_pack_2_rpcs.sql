-- 129: Report pack 2 RPCs - WinCloud-style report screens: pending KOT, pending bills, bill-wise detail, void bills,
-- settlement (payment modes), sales day book, sales month book, tax report.
--
-- Same safety and style as 128 (report_pack_rpcs) and sales_report (119):
--   * read-only, STABLE, SECURITY DEFINER, search_path = public, pg_temp, no dynamic SQL
--   * every function needs report.view_sales; the ones that show money collected, tax or the sales books ALSO need
--     report.view_financial (bill detail, settlement, day book, month book, tax). Pending KOT, pending bills and void bills
--     need the sales right only (an open bill / a void is an operational list, not a financial report).
--   * date range: same messages as sales_report ('Choose a valid date range.' / 'Choose a range of one year or less.')
--   * outlet scope from app.report_branch() (null = all outlets, only owner / unrestricted people; else the current outlet)
--   * own restaurant only; empty result = empty arrays, never null; revoked from public/anon, granted to authenticated
--   * business day = orders.business_date (not the calendar date)
-- Bills counted like sales_report: status 'completed' (or 'voided' for the void list), merged_into is null.
--
-- Return shapes (jsonb; every function returns an object that has "rows" (array) and "totals" (object)):
--   report_pending_kot(p_from, p_to)   {rows:[{kitchen_ticket_id, ticket_number, station, ticket_status, order_id, bill_number, order_status,
--                                        branch_id, outlet_name, table_number, order_type, kot_time, minutes_pending,
--                                        items:[{name, quantity, status, note}]}], totals:{kots, items}}
--   report_pending_bills(p_from, p_to) {rows:[{kind 'open'|'unsettled', order_id, bill_number, order_status, payment_status, branch_id, outlet_name,
--                                        table_number, order_type, waiter, cashier, business_date, created_at, amount, paid, balance, age_minutes}],
--                                        totals:{bills, amount, paid, balance}}
--   report_bills_detail(p_from, p_to)  {rows:[{order_id, bill_number, business_date, created_at, branch_id, outlet_name, table_number, order_type,
--                                        waiter, cashier, covers, comp_kind, payment_status, subtotal, discount, service_charge, tax, rounding,
--                                        grand_total, payments:[{method, kind, amount}]}], truncated, row_limit, total_rows,
--                                        totals:{bills, subtotal, discount, service_charge, tax, rounding, grand_total}}   (totals over ALL rows)
--   report_void_bills(p_from, p_to)    {rows:[{order_id, bill_number, business_date, voided_at, branch_id, outlet_name, table_number, order_type,
--                                        voided_by, reason, amount}], truncated, row_limit, total_rows, totals:{bills, amount}}
--   report_settlement(p_from, p_to)    {by_mode:[{method, kind, payments, bills, amount, rounding}],
--                                        by_outlet:[{branch_id, outlet_name, method, kind, payments, bills, amount}],
--                                        refunds:{count, amount, by_mode:[{method, kind, count, amount}], by_outlet:[{branch_id, outlet_name, count, amount}]},
--                                        rows:[{payment_id, paid_at, bill_number, business_date, branch_id, outlet_name, method, kind, amount, rounding,
--                                        reference_no, received_by}], truncated, row_limit, total_rows,
--                                        totals:{payments, amount, rounding, refunds, net}}   (totals over ALL payments)
--   report_sales_day_book(p_from, p_to)    {rows:[{business_date, bills, comp_bills, gross, discount, service_charge, tax, rounding, net_sales,
--                                        grand_total, cash, non_cash, unpaid}], totals:{same fields}}
--   report_sales_month_book(p_from, p_to)  same fields, but rows keyed by month: {month 'YYYY-MM', days, ...}; a range that starts or ends
--                                        mid-month gives a partial first / last month (only the days inside the range are added up)
--   report_tax(p_from, p_to)           {rows:[{component, rate, taxable, tax}], by_outlet:[{branch_id, outlet_name, component, rate, taxable, tax}],
--                                        totals:{taxable, tax, orders_tax_total, tax_included, exempt_sales}}
-- Money columns are JSON numbers.
-- Nothing is written. Safe to run again (create or replace).

-- ---------------------------------------------------------------- 1. pending KOT
-- A KOT (kitchen ticket) is pending while at least one of its lines is 'new' or 'preparing' (not ready / served / cancelled),
-- the ticket is not cancelled, the line is not cancelled on the bill, and the bill is still open (status open / placed / served,
-- i.e. not completed and not voided). Date filter: the BILL's business date (orders.business_date), so an old open bill
-- shows up when the range includes its day. Minutes pending = now - ticket created, from the ticket time.
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
      select kt.id as kt_id, kt.ticket_number, kt.station, kt.status as ticket_status, kt.created_at as kot_time,
             o.id as order_id, o.bill_number, o.status as order_status, o.branch_id, o.order_type, o.dining_table_id
        from public.kitchen_tickets kt
        join public.orders o on o.id = kt.order_id
       where kt.restaurant_id = v_rest and o.restaurant_id = v_rest
         and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.status in ('open', 'placed', 'served') and o.merged_into is null
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

-- ---------------------------------------------------------------- 2. pending bills
-- Two kinds of rows, both by the bill's business date:
--   'open'      table / running orders not yet billed (status open / placed / served); amount = running grand total
--   'unsettled' billed (completed) but not fully paid: payment_status unpaid / partial and balance > 0 (same test as the "unpaid" box of sales_report)
-- paid = captured payments less cash rounding (app.order_covered); balance = amount - paid; age = minutes since the bill was created.
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
             case when o.status = 'completed' then 'unsettled' else 'open' end as kind
        from public.orders o
       where o.restaurant_id = v_rest
         and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.merged_into is null
         and (o.status in ('open', 'placed', 'served')
              or (o.status = 'completed' and o.payment_status in ('unpaid', 'partial')))),
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

-- ---------------------------------------------------------------- 3. bill-wise detail
-- One row per completed (not merged) bill, complimentary and staff-meal bills included (comp_kind tells them apart; their
-- grand total is normally 0) so that the totals row equals sales_report's total_billed / tax / service_charge / rounding.
-- First 2000 rows (oldest first); "totals" are always computed over ALL matching bills, "truncated" says rows were cut.
create or replace function public.report_bills_detail(p_from date, p_to date) returns jsonb
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
    with o as (
      select ord.id, ord.bill_number, ord.business_date, ord.created_at, ord.branch_id, ord.dining_table_id, ord.order_type, ord.waiter_id, ord.cashier_id,
             ord.covers, ord.comp_kind, ord.payment_status, ord.subtotal, ord.discount_total, ord.service_charge, ord.tax_total,
             ord.rounding_adjustment, ord.grand_total
        from public.orders ord
       where ord.restaurant_id = v_rest
         and (v_rb is null or ord.branch_id = v_rb)
         and ord.business_date between p_from and p_to
         and ord.status = 'completed' and ord.merged_into is null),
    capped as (select * from o order by o.business_date, o.created_at, o.bill_number, o.id limit 2000)
    select jsonb_build_object(
      'rows', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'order_id', c.id, 'bill_number', c.bill_number, 'business_date', c.business_date, 'created_at', c.created_at,
                  'branch_id', c.branch_id, 'outlet_name', coalesce(b.name, 'Unknown outlet'), 'table_number', dt.table_number,
                  'order_type', c.order_type, 'waiter', w.full_name, 'cashier', u.full_name, 'covers', c.covers,
                  'comp_kind', c.comp_kind, 'payment_status', c.payment_status,
                  'subtotal', c.subtotal, 'discount', c.discount_total, 'service_charge', c.service_charge, 'tax', c.tax_total,
                  'rounding', c.rounding_adjustment, 'grand_total', c.grand_total,
                  'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', z.name, 'kind', z.kind, 'amount', z.amount) order by z.name), '[]'::jsonb)
                                 from (select pm.name, pm.kind, sum(p.amount) as amount
                                         from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
                                        where p.order_id = c.id and p.status = 'captured' group by pm.name, pm.kind) z))
                  order by c.business_date, c.created_at, c.bill_number, c.id)
           from capped c
           left join public.branches b on b.id = c.branch_id
           left join public.dining_tables dt on dt.id = c.dining_table_id
           left join public.users w on w.id = c.waiter_id
           left join public.users u on u.id = c.cashier_id), '[]'::jsonb),
      'truncated', (select count(*) from o) > 2000,
      'row_limit', 2000,
      'total_rows', (select count(*) from o),
      'totals', (select jsonb_build_object('bills', count(*), 'subtotal', coalesce(sum(o.subtotal), 0), 'discount', coalesce(sum(o.discount_total), 0),
                          'service_charge', coalesce(sum(o.service_charge), 0), 'tax', coalesce(sum(o.tax_total), 0),
                          'rounding', coalesce(sum(o.rounding_adjustment), 0), 'grand_total', coalesce(sum(o.grand_total), 0)) from o))
  );
end $$;

-- ---------------------------------------------------------------- 4. void bills
-- Bills with status 'voided' (not merged), by business date. Reason = audit_logs 'order.void' new_value.reason when present,
-- else orders.void_reason. Voided by = orders.voided_by, else the audit row's user. Time = orders.voided_at, else the audit time.
-- Amount = the bill's grand total at the time of the void. First 2000 rows, totals over all.
create or replace function public.report_void_bills(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return (
    with v as (
      select o.id, o.bill_number, o.business_date, o.branch_id, o.dining_table_id, o.order_type, o.grand_total,
             coalesce(o.voided_at, a.created_at, o.updated_at) as voided_at,
             coalesce(o.voided_by, a.user_id) as voided_by_id,
             coalesce(nullif(trim(a.new_value ->> 'reason'), ''), o.void_reason) as reason
        from public.orders o
        left join lateral (select al.created_at, al.user_id, al.new_value
                             from public.audit_logs al
                            where al.restaurant_id = v_rest and al.action = 'order.void' and al.entity_id = o.id
                            order by al.created_at desc, al.id desc limit 1) a on true
       where o.restaurant_id = v_rest
         and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.status = 'voided' and o.merged_into is null),
    capped as (select * from v order by v.business_date, v.voided_at, v.bill_number, v.id limit 2000)
    select jsonb_build_object(
      'rows', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'order_id', c.id, 'bill_number', c.bill_number, 'business_date', c.business_date, 'voided_at', c.voided_at,
                  'branch_id', c.branch_id, 'outlet_name', coalesce(b.name, 'Unknown outlet'), 'table_number', dt.table_number,
                  'order_type', c.order_type, 'voided_by', u.full_name, 'reason', c.reason, 'amount', c.grand_total)
                  order by c.business_date, c.voided_at, c.bill_number, c.id)
           from capped c
           left join public.branches b on b.id = c.branch_id
           left join public.dining_tables dt on dt.id = c.dining_table_id
           left join public.users u on u.id = c.voided_by_id), '[]'::jsonb),
      'truncated', (select count(*) from v) > 2000,
      'row_limit', 2000,
      'total_rows', (select count(*) from v),
      'totals', (select jsonb_build_object('bills', count(*), 'amount', coalesce(sum(v.grand_total), 0)) from v))
  );
end $$;

-- ---------------------------------------------------------------- 5. settlement (payment modes)
-- Payments: status 'captured', on completed (not merged) bills of the business-date range (same bills as sales_report). amount is the
-- amount received on the payment row (includes the cash rounding, which is shown separately as "rounding"), like sales_report by_method.
-- Refunds: refunds.created_at inside the range in the restaurant's time zone, bill in scope - exactly how sales_report counts "refunds".
-- Refund mode = refunds.payment_method_id, else the mode of the refunded payment, else 'Unspecified'.
-- net = payments - refunds. Detail rows: first 2000 payments (oldest first); totals over all.
create or replace function public.report_settlement(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_tz text; v_start timestamptz; v_end timestamptz;
begin
  perform app.require_permission('report.view_sales');
  if not app.has_permission('report.view_financial') then raise exception 'You do not have the right to see financial reports.'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;
  return (
    with pay as (
      select p.id, p.order_id, p.amount, coalesce(p.rounding_adjustment, 0) as rounding, p.reference_no, p.received_by, p.created_at,
             o.bill_number, o.business_date, o.branch_id, pm.id as method_id, pm.name as method, pm.kind
        from public.payments p
        join public.orders o on o.id = p.order_id
        join public.payment_methods pm on pm.id = p.payment_method_id
       where p.restaurant_id = v_rest and o.restaurant_id = v_rest
         and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.status = 'completed' and o.merged_into is null
         and p.status = 'captured'),
    ref as (
      select r.id, r.amount, o.branch_id,
             coalesce(pm.name, pm2.name, 'Unspecified') as method, coalesce(pm.kind, pm2.kind, 'other') as kind
        from public.refunds r
        join public.orders o on o.id = r.order_id
        left join public.payment_methods pm on pm.id = r.payment_method_id
        left join public.payments p on p.id = r.payment_id
        left join public.payment_methods pm2 on pm2.id = p.payment_method_id
       where r.restaurant_id = v_rest and o.restaurant_id = v_rest
         and (v_rb is null or o.branch_id = v_rb)
         and r.created_at >= v_start and r.created_at < v_end),
    capped as (select * from pay order by pay.created_at, pay.bill_number, pay.method, pay.id limit 2000)
    select jsonb_build_object(
      'by_mode', coalesce((select jsonb_agg(jsonb_build_object('method', x.method, 'kind', x.kind, 'payments', x.n, 'bills', x.bills,
                              'amount', x.amount, 'rounding', x.rounding) order by x.amount desc, x.method)
                             from (select method, kind, count(*) as n, count(distinct order_id) as bills, sum(amount) as amount, sum(rounding) as rounding
                                     from pay group by method, kind) x), '[]'::jsonb),
      'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', x.branch_id, 'outlet_name', x.outlet_name, 'method', x.method,
                              'kind', x.kind, 'payments', x.n, 'bills', x.bills, 'amount', x.amount) order by x.outlet_name, x.amount desc, x.method)
                               from (select pay.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, pay.method, pay.kind,
                                            count(*) as n, count(distinct pay.order_id) as bills, sum(pay.amount) as amount
                                       from pay left join public.branches b on b.id = pay.branch_id
                                      group by pay.branch_id, b.name, pay.method, pay.kind) x), '[]'::jsonb),
      'refunds', jsonb_build_object(
        'count', (select count(*) from ref), 'amount', coalesce((select sum(ref.amount) from ref), 0),
        'by_mode', coalesce((select jsonb_agg(jsonb_build_object('method', x.method, 'kind', x.kind, 'count', x.n, 'amount', x.amount) order by x.amount desc, x.method)
                               from (select method, kind, count(*) as n, sum(amount) as amount from ref group by method, kind) x), '[]'::jsonb),
        'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', x.branch_id, 'outlet_name', x.outlet_name, 'count', x.n, 'amount', x.amount)
                                                order by x.outlet_name)
                                 from (select ref.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, count(*) as n, sum(ref.amount) as amount
                                         from ref left join public.branches b on b.id = ref.branch_id group by ref.branch_id, b.name) x), '[]'::jsonb)),
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                  'payment_id', c.id, 'paid_at', c.created_at, 'bill_number', c.bill_number, 'business_date', c.business_date,
                  'branch_id', c.branch_id, 'outlet_name', coalesce(b.name, 'Unknown outlet'), 'method', c.method, 'kind', c.kind,
                  'amount', c.amount, 'rounding', c.rounding, 'reference_no', c.reference_no, 'received_by', u.full_name)
                  order by c.created_at, c.bill_number, c.method, c.id)
                 from capped c left join public.branches b on b.id = c.branch_id left join public.users u on u.id = c.received_by), '[]'::jsonb),
      'truncated', (select count(*) from pay) > 2000,
      'row_limit', 2000,
      'total_rows', (select count(*) from pay),
      'totals', jsonb_build_object(
         'payments', (select count(*) from pay), 'amount', coalesce((select sum(pay.amount) from pay), 0),
         'rounding', coalesce((select sum(pay.rounding) from pay), 0), 'refunds', coalesce((select sum(ref.amount) from ref), 0),
         'net', coalesce((select sum(pay.amount) from pay), 0) - coalesce((select sum(ref.amount) from ref), 0)))
  );
end $$;

-- ---------------------------------------------------------------- 6. sales day book / month book
-- Fields are built exactly like the summary of sales_report:
--   bills / gross / discount   completed bills that are NOT complimentary or staff-meal (comp_kind is null)
--   comp_bills                 complimentary + staff-meal bills
--   service_charge, tax, rounding, grand_total   all completed bills (grand_total = sales_report total_billed)
--   net_sales                  sum of order_items.net_amount of completed bills (same as sales_report net_sales)
--   cash / non_cash            captured payments on those bills by payment mode kind ('cash' vs every other kind), cash rounding included
--   unpaid                     grand_total less payments on completed bills still unpaid / partial (sales_report unpaid_amount)
create or replace function public.report_sales_day_book(p_from date, p_to date) returns jsonb
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
    with o as (
      select ord.id, ord.business_date, ord.comp_kind, ord.subtotal, ord.discount_total, ord.service_charge, ord.tax_total,
             ord.rounding_adjustment, ord.grand_total,
             case when ord.payment_status in ('unpaid', 'partial') then ord.grand_total - app.order_covered(ord.id) else 0 end as due,
             coalesce((select sum(oi.net_amount) from public.order_items oi where oi.order_id = ord.id), 0) as net,
             coalesce((select sum(p.amount) from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
                        where p.order_id = ord.id and p.status = 'captured' and pm.kind = 'cash'), 0) as cash,
             coalesce((select sum(p.amount) from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
                        where p.order_id = ord.id and p.status = 'captured' and pm.kind <> 'cash'), 0) as non_cash
        from public.orders ord
       where ord.restaurant_id = v_rest
         and (v_rb is null or ord.branch_id = v_rb)
         and ord.business_date between p_from and p_to
         and ord.status = 'completed' and ord.merged_into is null),
    d as (
      select o.business_date,
             count(*) filter (where o.comp_kind is null) as bills,
             count(*) filter (where o.comp_kind is not null) as comp_bills,
             coalesce(sum(o.subtotal) filter (where o.comp_kind is null), 0) as gross,
             coalesce(sum(o.discount_total) filter (where o.comp_kind is null), 0) as discount,
             coalesce(sum(o.service_charge), 0) as service_charge, coalesce(sum(o.tax_total), 0) as tax,
             coalesce(sum(o.rounding_adjustment), 0) as rounding, coalesce(sum(o.net), 0) as net_sales,
             coalesce(sum(o.grand_total), 0) as grand_total, sum(o.cash) as cash, sum(o.non_cash) as non_cash, sum(o.due) as unpaid
        from o group by o.business_date)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('business_date', d.business_date, 'bills', d.bills, 'comp_bills', d.comp_bills,
                 'gross', d.gross, 'discount', d.discount, 'service_charge', d.service_charge, 'tax', d.tax, 'rounding', d.rounding,
                 'net_sales', d.net_sales, 'grand_total', d.grand_total, 'cash', d.cash, 'non_cash', d.non_cash, 'unpaid', d.unpaid)
                 order by d.business_date) from d), '[]'::jsonb),
      'totals', jsonb_build_object('bills', coalesce((select sum(d.bills) from d), 0), 'comp_bills', coalesce((select sum(d.comp_bills) from d), 0),
                 'gross', coalesce((select sum(d.gross) from d), 0), 'discount', coalesce((select sum(d.discount) from d), 0),
                 'service_charge', coalesce((select sum(d.service_charge) from d), 0), 'tax', coalesce((select sum(d.tax) from d), 0),
                 'rounding', coalesce((select sum(d.rounding) from d), 0), 'net_sales', coalesce((select sum(d.net_sales) from d), 0),
                 'grand_total', coalesce((select sum(d.grand_total) from d), 0), 'cash', coalesce((select sum(d.cash) from d), 0),
                 'non_cash', coalesce((select sum(d.non_cash) from d), 0), 'unpaid', coalesce((select sum(d.unpaid) from d), 0)))
  );
end $$;

create or replace function public.report_sales_month_book(p_from date, p_to date) returns jsonb
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
    with o as (
      select ord.id, ord.business_date, ord.comp_kind, ord.subtotal, ord.discount_total, ord.service_charge, ord.tax_total,
             ord.rounding_adjustment, ord.grand_total,
             case when ord.payment_status in ('unpaid', 'partial') then ord.grand_total - app.order_covered(ord.id) else 0 end as due,
             coalesce((select sum(oi.net_amount) from public.order_items oi where oi.order_id = ord.id), 0) as net,
             coalesce((select sum(p.amount) from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
                        where p.order_id = ord.id and p.status = 'captured' and pm.kind = 'cash'), 0) as cash,
             coalesce((select sum(p.amount) from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
                        where p.order_id = ord.id and p.status = 'captured' and pm.kind <> 'cash'), 0) as non_cash
        from public.orders ord
       where ord.restaurant_id = v_rest
         and (v_rb is null or ord.branch_id = v_rb)
         and ord.business_date between p_from and p_to
         and ord.status = 'completed' and ord.merged_into is null),
    d as (
      select to_char(o.business_date, 'YYYY-MM') as month, count(distinct o.business_date) as days,
             count(*) filter (where o.comp_kind is null) as bills,
             count(*) filter (where o.comp_kind is not null) as comp_bills,
             coalesce(sum(o.subtotal) filter (where o.comp_kind is null), 0) as gross,
             coalesce(sum(o.discount_total) filter (where o.comp_kind is null), 0) as discount,
             coalesce(sum(o.service_charge), 0) as service_charge, coalesce(sum(o.tax_total), 0) as tax,
             coalesce(sum(o.rounding_adjustment), 0) as rounding, coalesce(sum(o.net), 0) as net_sales,
             coalesce(sum(o.grand_total), 0) as grand_total, sum(o.cash) as cash, sum(o.non_cash) as non_cash, sum(o.due) as unpaid
        from o group by to_char(o.business_date, 'YYYY-MM'))
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('month', d.month, 'days', d.days, 'bills', d.bills, 'comp_bills', d.comp_bills,
                 'gross', d.gross, 'discount', d.discount, 'service_charge', d.service_charge, 'tax', d.tax, 'rounding', d.rounding,
                 'net_sales', d.net_sales, 'grand_total', d.grand_total, 'cash', d.cash, 'non_cash', d.non_cash, 'unpaid', d.unpaid)
                 order by d.month) from d), '[]'::jsonb),
      'totals', jsonb_build_object('days', coalesce((select sum(d.days) from d), 0),
                 'bills', coalesce((select sum(d.bills) from d), 0), 'comp_bills', coalesce((select sum(d.comp_bills) from d), 0),
                 'gross', coalesce((select sum(d.gross) from d), 0), 'discount', coalesce((select sum(d.discount) from d), 0),
                 'service_charge', coalesce((select sum(d.service_charge) from d), 0), 'tax', coalesce((select sum(d.tax) from d), 0),
                 'rounding', coalesce((select sum(d.rounding) from d), 0), 'net_sales', coalesce((select sum(d.net_sales) from d), 0),
                 'grand_total', coalesce((select sum(d.grand_total) from d), 0), 'cash', coalesce((select sum(d.cash) from d), 0),
                 'non_cash', coalesce((select sum(d.non_cash) from d), 0), 'unpaid', coalesce((select sum(d.unpaid) from d), 0)))
  );
end $$;

-- ---------------------------------------------------------------- 7. tax report
-- Built exactly like sales_report "tax": order_item_taxes of completed (not merged) bills of the business-date range, grouped by
-- component name and rate, complimentary bills included (as sales_report does). Needs report.view_financial (sales_report only fills the tax
-- list for people who have it). "orders_tax_total" / "tax_included" / "exempt_sales" are the bill-header sums (sales_report summary tax,
-- tax_included, exempt_sales) so that any difference between the per-line breakdown and the bill totals stays visible.
create or replace function public.report_tax(p_from date, p_to date) returns jsonb
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
    with o as (
      select ord.id, ord.branch_id, ord.tax_total, ord.tax_included, ord.exempt_sales
        from public.orders ord
       where ord.restaurant_id = v_rest
         and (v_rb is null or ord.branch_id = v_rb)
         and ord.business_date between p_from and p_to
         and ord.status = 'completed' and ord.merged_into is null),
    t as (
      select o.branch_id, x.component_name, x.rate, x.taxable_amount, x.tax_amount
        from public.order_item_taxes x join o on o.id = x.order_id
       where x.restaurant_id = v_rest)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('component', z.component_name, 'rate', z.rate, 'taxable', z.taxable, 'tax', z.tax)
                                         order by z.rate, z.component_name)
                          from (select component_name, rate, sum(taxable_amount) as taxable, sum(tax_amount) as tax from t group by 1, 2) z), '[]'::jsonb),
      'by_outlet', coalesce((select jsonb_agg(jsonb_build_object('branch_id', z.branch_id, 'outlet_name', z.outlet_name, 'component', z.component_name,
                                                'rate', z.rate, 'taxable', z.taxable, 'tax', z.tax)
                                               order by z.outlet_name, z.rate, z.component_name)
                               from (select t.branch_id, coalesce(b.name, 'Unknown outlet') as outlet_name, t.component_name, t.rate,
                                            sum(t.taxable_amount) as taxable, sum(t.tax_amount) as tax
                                       from t left join public.branches b on b.id = t.branch_id
                                      group by t.branch_id, b.name, t.component_name, t.rate) z), '[]'::jsonb),
      'totals', jsonb_build_object(
         'taxable', coalesce((select sum(t.taxable_amount) from t), 0), 'tax', coalesce((select sum(t.tax_amount) from t), 0),
         'orders_tax_total', coalesce((select sum(o.tax_total) from o), 0), 'tax_included', coalesce((select sum(o.tax_included) from o), 0),
         'exempt_sales', coalesce((select sum(o.exempt_sales) from o), 0)))
  );
end $$;

revoke all on function public.report_pending_kot(date,date), public.report_pending_bills(date,date), public.report_bills_detail(date,date),
  public.report_void_bills(date,date), public.report_settlement(date,date), public.report_sales_day_book(date,date),
  public.report_sales_month_book(date,date), public.report_tax(date,date) from public, anon;
grant execute on function public.report_pending_kot(date,date), public.report_pending_bills(date,date), public.report_bills_detail(date,date),
  public.report_void_bills(date,date), public.report_settlement(date,date), public.report_sales_day_book(date,date),
  public.report_sales_month_book(date,date), public.report_tax(date,date) to authenticated;
