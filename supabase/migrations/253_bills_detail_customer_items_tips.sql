-- Bills detail: add customer name/GSTIN, tips and the item list per bill (for the optional tick-columns). Read-only change.
-- Rollback: recreate report_bills_detail from migration 252 (same function without buyer_name, buyer_gstin, tips, items).
do $$
declare d text;
begin
  d := pg_get_functiondef('public.report_bills_detail(date,date)'::regprocedure);
  d := replace(d, E'ord.session_name\n', E'ord.session_name, ord.buyer_name, ord.buyer_gstin\n');
  d := replace(d, E'''session'', coalesce(c.session_name, ''Other''),',
    E'''session'', coalesce(c.session_name, ''Other''), ''buyer_name'', c.buyer_name, ''buyer_gstin'', c.buyer_gstin,\n                  ''tips'', coalesce((select sum(tp.amount) from public.order_tips tp where tp.order_id = c.id), 0),\n                  ''items'', (select string_agg(i.product_name || '' x'' || trim_scale(i.quantity)::text, '', '' order by i.product_name) from public.order_items i where i.order_id = c.id and i.cancelled_at is null),');
  if position('buyer_gstin' in d) = 0 or position('''tips''' in d) = 0 or position('ord.buyer_name' in d) = 0 then raise exception 'patch report_bills_detail failed'; end if;
  execute d;
end $$;
