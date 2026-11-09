-- 185: the tax report shows credit notes on their own lines (credit-note-rules.md, point 7:
-- a credit note counts in the day it is issued; net = bills less credit notes).
create or replace function public.report_tax(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
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
      select ord.id, ord.branch_id, ord.tax_total, ord.tax_included, ord.exempt_sales
        from public.orders ord
       where ord.restaurant_id = v_rest
         and (v_rb is null or ord.branch_id = v_rb)
         and ord.business_date between p_from and p_to
         and ord.status = 'completed' and ord.merged_into is null),
    t as (
      select o.branch_id, x.component_name, x.rate, x.taxable_amount, x.tax_amount
        from public.order_item_taxes x join o on o.id = x.order_id
       where x.restaurant_id = v_rest),
    cnote as (
      select c.id, c.amount from public.credit_notes c
       where c.restaurant_id = v_rest and (v_rb is null or c.branch_id = v_rb) and c.business_date between p_from and p_to),
    cn as (
      select e->>'name' as component_name, (e->>'rate')::numeric as rate, (e->>'amount')::numeric as tax_amount
        from public.credit_notes c, jsonb_array_elements(c.taxes) e
       where c.id in (select id from cnote))
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
      'credit_rows', coalesce((select jsonb_agg(jsonb_build_object('component', z.component_name, 'rate', z.rate, 'tax', z.tax,
                                   'taxable', case when z.rate > 0 then round(z.tax * 100 / z.rate, 2) else 0 end)
                                 order by z.rate, z.component_name)
                          from (select component_name, rate, sum(tax_amount) as tax from cn group by 1, 2) z), '[]'::jsonb),
      'credit_totals', jsonb_build_object('count', (select count(*) from cnote), 'amount', coalesce((select sum(amount) from cnote), 0),
                                          'tax', coalesce((select sum(tax_amount) from cn), 0)),
      'totals', jsonb_build_object(
         'taxable', coalesce((select sum(t.taxable_amount) from t), 0), 'tax', coalesce((select sum(t.tax_amount) from t), 0),
         'orders_tax_total', coalesce((select sum(o.tax_total) from o), 0), 'tax_included', coalesce((select sum(o.tax_included) from o), 0),
         'exempt_sales', coalesce((select sum(o.exempt_sales) from o), 0)))
  );
end $$;
