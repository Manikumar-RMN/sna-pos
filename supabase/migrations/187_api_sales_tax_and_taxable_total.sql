-- 187: two money fixes found in the 9 Nov team audit.
-- 1) Open API 'sales': tax was tax_total + tax_included, which counts tax-inclusive items twice. Use tax_total only.
-- 2) Tax report: the Taxable total added each item once per tax component (CGST + SGST), doubling it. Count each item once.
do $$
declare def text; newdef text; oid_ oid;
begin
  select p.oid into oid_ from pg_proc p join pg_namespace s on s.oid=p.pronamespace where s.nspname='public' and p.proname='api_v1';
  def := pg_get_functiondef(oid_);
  newdef := replace(def, 'sum(o.tax_total + o.tax_included) filter', 'sum(o.tax_total) filter');
  if newdef <> def then execute newdef; end if;

  select p.oid into oid_ from pg_proc p join pg_namespace s on s.oid=p.pronamespace where s.nspname='public' and p.proname='report_tax';
  def := pg_get_functiondef(oid_);
  newdef := replace(def, 'select o.branch_id, x.component_name, x.rate, x.taxable_amount, x.tax_amount', 'select o.branch_id, x.order_item_id, x.component_name, x.rate, x.taxable_amount, x.tax_amount');
  newdef := replace(newdef, '''taxable'', coalesce((select sum(t.taxable_amount) from t), 0), ''tax''', '''taxable'', coalesce((select sum(q.taxable_amount) from (select distinct on (t.order_item_id) t.taxable_amount from t) q), 0), ''tax''');
  if newdef <> def then execute newdef; end if;
end $$;
