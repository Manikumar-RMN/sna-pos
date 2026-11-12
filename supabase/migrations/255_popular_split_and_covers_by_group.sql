-- Popular items split by meal session or month, and cover analysis by product group. Read-only functions.
-- Rollback: drop function public.report_popular_split(date, date, text); drop function public.report_covers_by_group(date, date);

CREATE OR REPLACE FUNCTION public.report_popular_split(p_from date, p_to date, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_feature('reports_mis');
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  if p_by not in ('session', 'month') then raise exception 'Split by session or month.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return coalesce((
    select jsonb_agg(jsonb_build_object('grp', t.grp, 'sort', t.sort, 'product_id', t.product_id, 'name', t.name, 'units', t.units, 'amount', t.amount)
                     order by t.sort, t.grp, t.units desc, t.amount desc, t.name)
      from (
        select x.*, row_number() over (partition by x.grp order by x.units desc, x.amount desc, x.name) rn
          from (
            select case when p_by = 'month' then to_char(o.business_date, 'YYYY-MM') else coalesce(o.session_name, 'Other') end grp,
                   case when p_by = 'month' then 0 else min(coalesce(ms.display_order, 99)) end sort,
                   oi.product_id, min(oi.product_name) name,
                   round(sum(oi.quantity), 2) units, round(sum(oi.line_subtotal), 2) amount
              from public.order_items oi
              join public.orders o on o.id = oi.order_id
              left join public.meal_sessions ms on ms.id = o.session_id
             where o.restaurant_id = v_rest and (v_rb is null or o.branch_id = v_rb)
               and o.business_date between p_from and p_to and o.status = 'completed' and o.merged_into is null and oi.cancelled_at is null
             group by 1, oi.product_id, case when oi.product_id is null then oi.product_name end) x) t
     where t.rn <= 30), '[]'::jsonb);
end $function$;
GRANT EXECUTE ON FUNCTION public.report_popular_split(date, date, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.report_covers_by_group(p_from date, p_to date)
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
  return (
    with b as (
      select o.id, o.covers from public.orders o
       where o.restaurant_id = v_rest and (v_rb is null or o.branch_id = v_rb)
         and o.business_date between p_from and p_to and o.status = 'completed' and o.merged_into is null
         and o.order_type = 'dine_in' and coalesce(o.covers, 0) > 0)
    select jsonb_build_object(
      'covers', coalesce((select sum(covers) from b), 0),
      'bills', (select count(*) from b),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object('group', g.grp, 'units', g.units, 'amount', g.amount, 'bills', g.bills) order by g.amount desc, g.grp)
          from (select coalesce(c.name, 'No group') grp, round(sum(oi.quantity), 2) units, round(sum(oi.line_subtotal), 2) amount, count(distinct oi.order_id) bills
                  from public.order_items oi
                  join b on b.id = oi.order_id
                  left join public.products p on p.id = oi.product_id
                  left join public.categories c on c.id = p.category_id
                 where oi.cancelled_at is null
                 group by coalesce(c.name, 'No group')) g), '[]'::jsonb))
  );
end $function$;
GRANT EXECUTE ON FUNCTION public.report_covers_by_group(date, date) TO authenticated;
