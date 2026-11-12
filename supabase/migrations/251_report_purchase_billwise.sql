-- Purchase bill-wise register (GST India): one row per goods receipt, net of goods sent back. Read-only.
-- Rollback: drop function public.report_purchase_billwise(date, date);
CREATE OR REPLACE FUNCTION public.report_purchase_billwise(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_rb uuid; v_own text;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  select left(upper(regexp_replace(coalesce(tax_registration_no, ''), '\s', '', 'g')), 2) into v_own from public.restaurants where id = v_rest;
  -- goods_receipts.total is already net of returns; returned_total includes the returned tax.
  return (
    select jsonb_build_object('rows', coalesce(jsonb_agg(r order by r->>'date', r->>'number'), '[]'::jsonb)) from (
      select jsonb_build_object(
        'number', g.number, 'date', g.received_on, 'supplier', s.name, 'gstin', nullif(s.tax_no, ''),
        'bill_no', g.supplier_bill_no, 'bill_date', g.supplier_bill_date,
        'kind', case when v_own ~ '^[0-9]{2}$' and left(upper(regexp_replace(coalesce(s.tax_no, ''), '\s', '', 'g')), 2) ~ '^[0-9]{2}$'
                     then (case when v_own = left(upper(regexp_replace(s.tax_no, '\s', '', 'g')), 2) then 'intra' else 'inter' end) else 'unknown' end,
        'taxable', round(g.subtotal - (coalesce(g.returned_total, 0) - coalesce(g.returned_tax, 0)), 2),
        'tax', round(g.tax_amount - coalesce(g.returned_tax, 0), 2),
        'other_charges', g.other_charges,
        'total', round(g.total, 2),
        'claimable_tax', round(coalesce(g.input_tax_claimable, 0), 2),
        'type', g.receipt_type) r
      from public.goods_receipts g
      join public.suppliers s on s.id = g.supplier_id
     where g.restaurant_id = v_rest and (v_rb is null or g.branch_id = v_rb) and g.received_on between p_from and p_to
       and g.status <> 'cancelled') x);
end $function$;
GRANT EXECUTE ON FUNCTION public.report_purchase_billwise(date, date) TO authenticated;
