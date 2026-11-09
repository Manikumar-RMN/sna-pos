-- 186: the sales day book and the monthwise book return credit notes issued in each day / month on their own
-- 'credit_rows' (count, amount, tax). Credit notes count in the day they are issued (credit-note-rules.md, point 7).
do $$
declare def text; newdef text; oid_ oid; fn text; keyexpr text; keyname text; ins text;
begin
  foreach fn in array array['report_sales_day_book','report_sales_month_book'] loop
    select p.oid into oid_ from pg_proc p join pg_namespace s on s.oid=p.pronamespace where s.nspname='public' and p.proname=fn;
    def := pg_get_functiondef(oid_);
    if def like '%credit_rows%' then continue; end if;
    if fn = 'report_sales_day_book' then keyexpr := 'c.business_date'; keyname := 'business_date';
    else keyexpr := $k$to_char(c.business_date, 'YYYY-MM')$k$; keyname := 'month'; end if;
    ins := format($f$      'credit_rows', coalesce((select jsonb_agg(jsonb_build_object(%L, z.k, 'count', z.n, 'amount', z.amount, 'tax', z.tax) order by z.k)
                          from (select %s as k, count(*) as n, sum(c.amount) as amount, sum(c.tax_amount) as tax
                                  from public.credit_notes c
                                 where c.restaurant_id = v_rest and (v_rb is null or c.branch_id = v_rb) and c.business_date between p_from and p_to
                                 group by 1) z), '[]'::jsonb),
$f$, keyname, keyexpr);
    newdef := replace(def, E'    select jsonb_build_object(\n      ''rows'',', E'    select jsonb_build_object(\n' || ins || E'      ''rows'',');
    if newdef = def then raise exception 'pattern not found in %', fn; end if;
    execute newdef;
  end loop;
end $$;
