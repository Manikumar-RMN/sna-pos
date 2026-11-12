-- Two read-only report functions: settlement by day and payment type, and pre-order advances (received, adjusted, refunded).
-- Rollback: drop function public.report_settlement_type(date, date); drop function public.report_advances(date, date);

CREATE OR REPLACE FUNCTION public.report_settlement_type(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_feature('reports_mis');
  perform app.require_permission('report.view_financial');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return jsonb_build_object('rows', coalesce((
    select jsonb_agg(jsonb_build_object('outlet_name', z.outlet, 'business_date', z.d, 'kind', z.kind, 'method', z.method, 'payments', z.n, 'amount', z.amt)
                     order by z.outlet, z.d, z.kind, z.method)
      from (select coalesce(b.name, 'Unknown outlet') outlet, o.business_date d, m.kind, m.name method, count(*) n, sum(p.amount) amt
              from public.payments p
              join public.orders o on o.id = p.order_id
              join public.payment_methods m on m.id = p.payment_method_id
              left join public.branches b on b.id = o.branch_id
             where o.restaurant_id = v_rest and (v_rb is null or o.branch_id = v_rb)
               and o.business_date between p_from and p_to and o.status = 'completed' and o.merged_into is null
               and p.status = 'captured'
             group by 1, 2, 3, 4) z), '[]'::jsonb));
end $function$;
GRANT EXECUTE ON FUNCTION public.report_settlement_type(date, date) TO authenticated;

CREATE OR REPLACE FUNCTION public.report_advances(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_feature('reports_mis');
  perform app.require_permission('report.view_financial');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return jsonb_build_object('rows', coalesce((
    select jsonb_agg(to_jsonb(y) order by y.outlet_name, y.number)
      from (
        select x.*,
               case when x.adjusted_date between p_from and p_to and x.first_date between p_from and p_to then 'Current'
                    when x.adjusted_date between p_from and p_to and x.first_date < p_from then 'Past'
                    when x.adjusted_date is null and x.received_in_period > 0 then 'Held'
                    else 'Other' end as period_kind
          from (
            select pr.number, pr.guest_name, pr.status, coalesce(b.name, 'Unknown outlet') outlet_name,
                   (select min((pp.created_at at time zone coalesce(b.timezone, r.timezone, 'UTC'))::date) from public.pre_order_payments pp where pp.pre_order_id = pr.id and pp.kind = 'advance') first_date,
                   coalesce((select sum(pp.amount) from public.pre_order_payments pp where pp.pre_order_id = pr.id and pp.kind = 'advance'), 0) received,
                   coalesce((select sum(pp.amount) from public.pre_order_payments pp where pp.pre_order_id = pr.id and pp.kind = 'advance'
                              and (pp.created_at at time zone coalesce(b.timezone, r.timezone, 'UTC'))::date between p_from and p_to), 0) received_in_period,
                   coalesce((select sum(pp.amount) from public.pre_order_payments pp where pp.pre_order_id = pr.id and pp.kind = 'refund'), 0) refunded,
                   coalesce((select sum(py.amount) from public.payments py join public.payment_methods m on m.id = py.payment_method_id
                              where py.order_id = pr.order_id and m.kind = 'advance' and py.status = 'captured'), 0) adjusted,
                   (select o.bill_number from public.orders o where o.id = pr.order_id) bill_number,
                   (select o.business_date from public.orders o where o.id = pr.order_id and o.status = 'completed') adjusted_date,
                   app.pre_order_held(pr.id) held
              from public.pre_orders pr
              join public.restaurants r on r.id = pr.restaurant_id
              left join public.branches b on b.id = pr.branch_id
             where pr.restaurant_id = v_rest and (v_rb is null or pr.branch_id = v_rb)) x
         where x.received_in_period > 0 or x.adjusted_date between p_from and p_to) y), '[]'::jsonb));
end $function$;
GRANT EXECUTE ON FUNCTION public.report_advances(date, date) TO authenticated;
