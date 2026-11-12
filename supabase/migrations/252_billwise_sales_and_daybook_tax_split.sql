-- Sales bill-wise register (summary and details) and the tax split + session on the per-bill day book.
-- Read-only functions. Rollback: drop function public.report_sales_billwise(date, date); then recreate report_bills_detail from migration history (previous body had no session/cgst/sgst/igst keys).

-- 1) report_bills_detail: add session, cgst, sgst, igst per bill (same rows, same cap as before).
CREATE OR REPLACE FUNCTION public.report_bills_detail(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_feature('reports_mis');
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
             ord.rounding_adjustment, ord.grand_total, ord.session_name
        from public.orders ord
       where ord.restaurant_id = v_rest
         and (v_rb is null or ord.branch_id = v_rb)
         and ord.business_date between p_from and p_to
         and ord.status = 'completed' and ord.merged_into is null),
    capped as (select * from o order by o.business_date, o.created_at, o.bill_number, o.id limit 2000),
    tx as (
      select oi.order_id,
             sum(case when t.component_name ilike 'CGST%' then t.tax_amount else 0 end) cgst,
             sum(case when t.component_name ilike 'SGST%' or t.component_name ilike 'UTGST%' then t.tax_amount else 0 end) sgst,
             sum(case when t.component_name ilike 'IGST%' then t.tax_amount else 0 end) igst
        from public.order_items oi
        join public.order_item_taxes t on t.order_item_id = oi.id
       where oi.cancelled_at is null and oi.order_id in (select id from capped)
       group by oi.order_id)
    select jsonb_build_object(
      'rows', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'order_id', c.id, 'bill_number', c.bill_number, 'business_date', c.business_date, 'created_at', c.created_at,
                  'branch_id', c.branch_id, 'outlet_name', coalesce(b.name, 'Unknown outlet'), 'table_number', dt.table_number,
                  'order_type', c.order_type, 'waiter', w.full_name, 'cashier', u.full_name, 'covers', c.covers,
                  'comp_kind', c.comp_kind, 'payment_status', c.payment_status,
                  'session', coalesce(c.session_name, 'Other'),
                  'subtotal', c.subtotal, 'discount', c.discount_total, 'service_charge', c.service_charge, 'tax', c.tax_total,
                  'cgst', coalesce(x.cgst, 0), 'sgst', coalesce(x.sgst, 0), 'igst', coalesce(x.igst, 0),
                  'rounding', c.rounding_adjustment, 'grand_total', c.grand_total,
                  'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', z.name, 'kind', z.kind, 'amount', z.amount) order by z.name), '[]'::jsonb)
                                 from (select pm.name, pm.kind, sum(p.amount) as amount
                                         from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
                                        where p.order_id = c.id and p.status = 'captured' group by pm.name, pm.kind) z))
                  order by c.business_date, c.created_at, c.bill_number, c.id)
           from capped c
           left join tx x on x.order_id = c.id
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
end $function$;

-- 2) Sales bill-wise register: one entry per finished bill with its tax split and its item lines (HSN/SAC, rate, taxable value, CGST/SGST/IGST).
CREATE OR REPLACE FUNCTION public.report_sales_billwise(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_rb uuid; v_sac text;
begin
  perform app.require_feature('reports_mis');
  perform app.require_permission('report.view_financial');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  select coalesce(nullif(sac_code, ''), '9963') into v_sac from public.restaurants where id = v_rest;
  return (
    with o as (
      select ord.id, ord.bill_number, ord.business_date, ord.created_at, ord.branch_id, ord.comp_kind, ord.session_name,
             ord.buyer_gstin, ord.buyer_name, ord.subtotal, ord.discount_total, ord.service_charge, ord.tax_total,
             ord.rounding_adjustment, ord.grand_total
        from public.orders ord
       where ord.restaurant_id = v_rest and (v_rb is null or ord.branch_id = v_rb)
         and ord.business_date between p_from and p_to
         and ord.status = 'completed' and ord.merged_into is null),
    capped as (select * from o order by o.business_date, o.created_at, o.bill_number, o.id limit 2000),
    li as (
      select oi.order_id, oi.id item_id, oi.product_name item, coalesce(nullif(p.hsn_code, ''), v_sac) hsn,
             coalesce(nullif(oi.unit, ''), 'NOS') uqc, oi.quantity qty,
             coalesce((select sum(t.rate) from public.order_item_taxes t where t.order_item_id = oi.id and t.component_name !~* 'cess'), 0) rate,
             coalesce((select max(t.taxable_amount) from public.order_item_taxes t where t.order_item_id = oi.id), oi.net_amount) taxable,
             coalesce((select sum(t.tax_amount) from public.order_item_taxes t where t.order_item_id = oi.id and t.component_name ilike 'CGST%'), 0) cgst,
             coalesce((select sum(t.tax_amount) from public.order_item_taxes t where t.order_item_id = oi.id and (t.component_name ilike 'SGST%' or t.component_name ilike 'UTGST%')), 0) sgst,
             coalesce((select sum(t.tax_amount) from public.order_item_taxes t where t.order_item_id = oi.id and t.component_name ilike 'IGST%'), 0) igst
        from public.order_items oi
        join capped c on c.id = oi.order_id
        left join public.products p on p.id = oi.product_id
       where oi.cancelled_at is null)
    select jsonb_build_object(
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'bill_number', c.bill_number, 'business_date', c.business_date, 'outlet_name', coalesce(b.name, 'Unknown outlet'),
                 'session', coalesce(c.session_name, 'Other'), 'comp_kind', c.comp_kind,
                 'buyer_gstin', c.buyer_gstin, 'buyer_name', c.buyer_name,
                 'gross', c.subtotal, 'discount', c.discount_total, 'service_charge', c.service_charge, 'tax', c.tax_total,
                 'rounding', c.rounding_adjustment, 'grand_total', c.grand_total,
                 'taxable', coalesce((select sum(l.taxable) from li l where l.order_id = c.id), 0),
                 'cgst', coalesce((select sum(l.cgst) from li l where l.order_id = c.id), 0),
                 'sgst', coalesce((select sum(l.sgst) from li l where l.order_id = c.id), 0),
                 'igst', coalesce((select sum(l.igst) from li l where l.order_id = c.id), 0),
                 'lines', coalesce((select jsonb_agg(jsonb_build_object('item', l.item, 'hsn', l.hsn, 'uqc', l.uqc, 'qty', l.qty, 'rate', l.rate,
                                      'taxable', l.taxable, 'cgst', l.cgst, 'sgst', l.sgst, 'igst', l.igst) order by l.item)
                                      from li l where l.order_id = c.id), '[]'::jsonb))
               order by coalesce(b.name, ''), c.business_date, c.created_at, c.bill_number)
          from capped c left join public.branches b on b.id = c.branch_id), '[]'::jsonb),
      'truncated', (select count(*) from o) > 2000,
      'total_rows', (select count(*) from o))
  );
end $function$;
GRANT EXECUTE ON FUNCTION public.report_sales_billwise(date, date) TO authenticated;
