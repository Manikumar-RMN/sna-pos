-- Outlet comparison: bills, average bill and discounts follow the Sales summary rule (free meals are counted apart, not as bills).
-- Rollback: recreate the function without the "and o.comp_kind is null" filters.
CREATE OR REPLACE FUNCTION public.outlet_comparison(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_permission('report.view_sales');
  perform app.require_feature('multi_outlet');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a valid date range (one year or less).'; end if;
  return (select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc), '[]'::jsonb) from (
    select jsonb_build_object('outlet', b.name, 'code', b.code,
      'bills', count(o.id) filter (where o.status = 'completed' and o.comp_kind is null),
      'total', coalesce(sum(o.grand_total) filter (where o.status = 'completed'), 0),
      'average', coalesce(round(avg(o.grand_total) filter (where o.status = 'completed' and o.comp_kind is null), 2), 0),
      'discounts', coalesce(sum(o.discount_total) filter (where o.status = 'completed' and o.comp_kind is null), 0),
      'voids', count(o.id) filter (where o.status = 'voided'),
      'void_value', coalesce(sum(o.grand_total) filter (where o.status = 'voided'), 0)) x
      from public.branches b
      left join public.orders o on o.branch_id = b.id and o.merged_into is null and o.business_date between p_from and p_to
     where b.restaurant_id = v_rest and b.deleted_at is null and app.can_use_branch(b.id)
     group by b.id, b.name, b.code) z);
end $function$;
