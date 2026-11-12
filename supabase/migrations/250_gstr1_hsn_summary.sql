-- GSTR-1 Table 12: HSN/SAC summary of finished bills, B2B and B2C apart (India). Read-only function. Rollback: drop function public.gstr1_hsn_summary(date, date);
CREATE OR REPLACE FUNCTION public.gstr1_hsn_summary(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_sac text; v_rows jsonb;
begin
  perform app.require_feature('reports_mis');
  perform app.require_permission('report.view_financial');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select coalesce(nullif(sac_code, ''), '9963') into v_sac from public.restaurants where id = v_rest;
  select coalesce(jsonb_agg(r order by r->>'supply', r->>'hsn', (r->>'rate')::numeric), '[]'::jsonb) into v_rows from (
    select jsonb_build_object(
      'supply', case when l.b2b then 'B2B' else 'B2C' end,
      'hsn', l.hsn, 'uqc', l.uqc, 'rate', l.rate,
      'quantity', sum(l.qty), 'taxable', sum(l.taxable),
      'cgst', sum(l.cgst), 'sgst', sum(l.sgst), 'igst', sum(l.igst),
      'total', sum(l.taxable + l.cgst + l.sgst + l.igst)) r
    from (
      select (o.buyer_gstin is not null and o.buyer_gstin <> '') b2b,
             coalesce(nullif(p.hsn_code, ''), v_sac) hsn,
             coalesce(nullif(oi.unit, ''), 'NOS') uqc,
             coalesce((select sum(t.rate) from public.order_item_taxes t where t.order_item_id = oi.id and t.component_name !~* 'cess'), 0) rate,
             oi.quantity qty,
             coalesce((select max(t.taxable_amount) from public.order_item_taxes t where t.order_item_id = oi.id), oi.net_amount) taxable,
             coalesce((select sum(t.tax_amount) from public.order_item_taxes t where t.order_item_id = oi.id and t.component_name ilike 'CGST%'), 0) cgst,
             coalesce((select sum(t.tax_amount) from public.order_item_taxes t where t.order_item_id = oi.id and (t.component_name ilike 'SGST%' or t.component_name ilike 'UTGST%')), 0) sgst,
             coalesce((select sum(t.tax_amount) from public.order_item_taxes t where t.order_item_id = oi.id and t.component_name ilike 'IGST%'), 0) igst
        from public.orders o
        join public.order_items oi on oi.order_id = o.id and oi.cancelled_at is null
        left join public.products p on p.id = oi.product_id
       where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.business_date between p_from and p_to
         and o.merged_into is null and o.status = 'completed') l
    group by l.b2b, l.hsn, l.uqc, l.rate) x;
  return v_rows;
end $function$;
GRANT EXECUTE ON FUNCTION public.gstr1_hsn_summary(date, date) TO authenticated;
