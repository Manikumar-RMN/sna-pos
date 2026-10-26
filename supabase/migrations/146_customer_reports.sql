-- 146: customer reports (pattern of 138: read-only, STABLE, SECURITY DEFINER, outlet scope from app.report_branch(), business-day filtering,
-- 366-day cap, revoked from public/anon, granted to authenticated).
--
-- report_customers(p_from, p_to)     needs customer.view AND report.view_sales. Money (spend) only for people who ALSO have report.view_financial
--                                    (else null and "money": false, as report_covers).
--   {money, by_customer:[top 500 by spend (then visits): customer_id, name, phone, visits, spend, avg_bill, first_visit_on, last_visit_on, is_new],
--    by_day:[{business_date, bills_with_customer, new_customers, repeat_customers, spend}],
--    totals:{customers, new, repeat, repeat_rate, spend, bills_with_customer, bills_total, capture_rate}}
--   A visit is a bill with a customer, payment_status 'paid' or 'partially_refunded', status <> 'voided', not merged away, on a business_date in the range, in the outlet scope.
--   spend = grand_total minus the bill's credit notes. first_visit_on / is_new look at the guest's first visit EVER in the same outlet scope; "new" = that first
--   visit is inside the range, "repeat" (returning) = every other guest who visited in the range; repeat_rate and capture_rate are percentages with 1 decimal.
--   bills_total counts every paid, not voided, not merged bill in the range (the denominator of capture_rate = share of bills that carried a guest).
-- report_loyalty_ledger(p_from, p_to) needs customer.view AND the loyalty module. Ledger rows are dated by the bill's business_date (rows with no bill: the day in
--   the restaurant's time zone) and belong to the outlet of the bill; rows with no bill (manual / data deletion) are restaurant-wide and appear only when the
--   scope is All outlets (outlet "Manual").
--   {by_day:[{business_date, earned, redeemed, reversed, adjusted}], rows:[newest first, max 2000: at, business_date, customer, kind, points, bill_number, outlet, user],
--    truncated, row_limit, total_rows, totals:{earned, redeemed, reversed, adjusted, net},
--    liability:{points_outstanding, rupee_value, customers_with_points}}
--   earned = kind earn; redeemed = -(kind redeem) (positive); reversed = -(kind reverse) (positive); adjusted = adjust + expire (signed); net = sum of all points.
--   liability is as of now and restaurant-wide (points belong to the guest, not to an outlet): positive balances only, valued at point_value.
-- Re-runnable (create or replace).

create or replace function public.report_customers(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_money boolean;
begin
  perform app.require_permission('customer.view');
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest  := app.current_restaurant_id();
  v_rb    := app.report_branch();
  v_money := app.has_permission('report.view_financial');
  return (
    with v as (   -- every visit in the range
      select o.id, o.customer_id, o.business_date, o.grand_total - coalesce((select sum(cn.amount) from public.credit_notes cn where cn.order_id = o.id), 0) as net
        from public.orders o
       where o.restaurant_id = v_rest and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to
         and o.customer_id is not null and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null),
    ff as (       -- first visit ever of each of those guests (same outlet scope)
      select o.customer_id, min(o.business_date) as first_on
        from public.orders o
       where o.restaurant_id = v_rest and (v_rb is null or o.branch_id = v_rb)
         and o.customer_id in (select customer_id from v)
         and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null
       group by o.customer_id),
    cu as (
      select v.customer_id, count(*) as visits, sum(v.net) as spend, max(v.business_date) as last_on, ff.first_on, (ff.first_on between p_from and p_to) as is_new
        from v join ff on ff.customer_id = v.customer_id group by v.customer_id, ff.first_on),
    dy as (
      select v.business_date, count(*) as bills, sum(v.net) as spend,
             count(distinct v.customer_id) filter (where ff.first_on = v.business_date) as new_c,
             count(distinct v.customer_id) filter (where ff.first_on < v.business_date) as repeat_c
        from v join ff on ff.customer_id = v.customer_id group by v.business_date),
    bt as (
      select count(*) as n from public.orders o
       where o.restaurant_id = v_rest and (v_rb is null or o.branch_id = v_rb) and o.business_date between p_from and p_to
         and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null)
    select jsonb_build_object(
      'money', v_money,
      'by_customer', coalesce((select jsonb_agg(jsonb_build_object('customer_id', t.customer_id, 'name', c.name, 'phone', c.phone, 'visits', t.visits,
                 'spend', case when v_money then t.spend end, 'avg_bill', case when v_money then round(t.spend / t.visits, 2) end,
                 'first_visit_on', t.first_on, 'last_visit_on', t.last_on, 'is_new', t.is_new) order by t.spend desc, t.visits desc, c.name, t.customer_id)
                 from (select * from cu order by spend desc, visits desc, customer_id limit 500) t join public.customers c on c.id = t.customer_id), '[]'::jsonb),
      'by_day', coalesce((select jsonb_agg(jsonb_build_object('business_date', d.business_date, 'bills_with_customer', d.bills,
                 'new_customers', d.new_c, 'repeat_customers', d.repeat_c, 'spend', case when v_money then d.spend end) order by d.business_date) from dy d), '[]'::jsonb),
      'totals', jsonb_build_object(
         'customers', (select count(*) from cu),
         'new', (select count(*) from cu where cu.is_new),
         'repeat', (select count(*) from cu where not cu.is_new),
         'repeat_rate', case when (select count(*) from cu) > 0 then round(100.0 * (select count(*) from cu where not cu.is_new) / (select count(*) from cu), 1) else 0 end,
         'spend', case when v_money then coalesce((select sum(v.net) from v), 0) end,
         'bills_with_customer', (select count(*) from v),
         'bills_total', (select n from bt),
         'capture_rate', case when (select n from bt) > 0 then round(100.0 * (select count(*) from v) / (select n from bt), 1) else 0 end))
  );
end $$;

create or replace function public.report_loyalty_ledger(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid; v_tz text; v_pv numeric;
begin
  perform app.require_permission('customer.view');
  perform app.require_feature('loyalty');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  select coalesce(nullif(timezone, ''), 'UTC') into v_tz from public.restaurants where id = v_rest;
  select s.point_value into v_pv from public.loyalty_settings s where s.restaurant_id = v_rest;
  return (
    with l as (
      select g.id, g.created_at, g.customer_id, g.kind, g.points, g.created_by, g.order_id,
             coalesce(o.business_date, (g.created_at at time zone v_tz)::date) as d,
             o.bill_number, o.branch_id
        from public.loyalty_ledger g left join public.orders o on o.id = g.order_id
       where g.restaurant_id = v_rest
         and (case when g.order_id is null then v_rb is null else (v_rb is null or o.branch_id = v_rb) end)
         and coalesce(o.business_date, (g.created_at at time zone v_tz)::date) between p_from and p_to),
    bal as (select g.customer_id, sum(g.points) as b from public.loyalty_ledger g where g.restaurant_id = v_rest group by g.customer_id having sum(g.points) > 0)
    select jsonb_build_object(
      'by_day', coalesce((select jsonb_agg(jsonb_build_object('business_date', x.d, 'earned', x.earned, 'redeemed', x.redeemed, 'reversed', x.reversed, 'adjusted', x.adjusted) order by x.d)
                 from (select l.d, coalesce(sum(l.points) filter (where l.kind = 'earn'), 0) as earned, coalesce(-sum(l.points) filter (where l.kind = 'redeem'), 0) as redeemed,
                              coalesce(-sum(l.points) filter (where l.kind = 'reverse'), 0) as reversed, coalesce(sum(l.points) filter (where l.kind in ('adjust', 'expire')), 0) as adjusted
                         from l group by l.d) x), '[]'::jsonb),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('at', y.created_at, 'business_date', y.d, 'customer', coalesce(c.name, 'Guest'), 'kind', y.kind, 'points', y.points,
                 'bill_number', y.bill_number, 'outlet', case when y.order_id is null then 'Manual' else coalesce(b.name, '') end, 'user', u.full_name)
                 order by y.created_at desc, y.id)
                 from (select * from l order by created_at desc, id limit 2000) y
                 left join public.customers c on c.id = y.customer_id left join public.branches b on b.id = y.branch_id left join public.users u on u.id = y.created_by), '[]'::jsonb),
      'truncated', (select count(*) from l) > 2000, 'row_limit', 2000, 'total_rows', (select count(*) from l),
      'totals', jsonb_build_object(
         'earned', coalesce((select sum(l.points) from l where l.kind = 'earn'), 0),
         'redeemed', coalesce(-(select sum(l.points) from l where l.kind = 'redeem'), 0),
         'reversed', coalesce(-(select sum(l.points) from l where l.kind = 'reverse'), 0),
         'adjusted', coalesce((select sum(l.points) from l where l.kind in ('adjust', 'expire')), 0),
         'net', coalesce((select sum(l.points) from l), 0)),
      'liability', jsonb_build_object('points_outstanding', coalesce((select sum(b) from bal), 0),
         'rupee_value', round(coalesce((select sum(b) from bal), 0) * coalesce(v_pv, 0), 2), 'customers_with_points', (select count(*) from bal)))
  );
end $$;

revoke all on function public.report_customers(date, date), public.report_loyalty_ledger(date, date) from public, anon;
grant execute on function public.report_customers(date, date), public.report_loyalty_ledger(date, date) to authenticated;
