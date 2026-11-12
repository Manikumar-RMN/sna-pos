-- Settlement by payment mode (Sales summary): count payments, and payments on voided bills, by the BILL's business day,
-- not by the clock time the payment was keyed in. A bill of 11 Nov settled at 11:05 on 12 Nov (day still open) belongs to 11 Nov,
-- as it already does in the accounting export. Refunds stay on the day they were paid back.
create or replace function public.settlement_report(p_from date, p_to date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_methods jsonb; v_rows jsonb;
begin
  perform app.require_feature('reports_mis');
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  with pay as (
    select p.payment_method_id m, count(*) n, sum(p.amount) amt
      from public.payments p join public.orders o on o.id = p.order_id
     where p.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.business_date between p_from and p_to
       and p.status in ('captured', 'refunded')
     group by 1),
  ref as (
    select p.payment_method_id m, sum(r.amount) amt
      from public.refunds r join public.payments p on p.id = r.payment_id
     where r.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = p.order_id)) and r.created_at >= v_start and r.created_at < v_end
     group by 1),
  voids as (
    select p.payment_method_id m, sum(p.amount) amt
      from public.payments p join public.orders o on o.id = p.order_id
     where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.status = 'voided' and o.business_date between p_from and p_to
       and p.status = 'refunded'
     group by 1)
  select coalesce(jsonb_agg(jsonb_build_object(
           'method', pm.name, 'kind', pm.kind, 'mode', pm.collection_mode,
           'payments', coalesce(pay.n, 0), 'collected', coalesce(pay.amt, 0),
           'refunded', coalesce(ref.amt, 0), 'voided', coalesce(voids.amt, 0),
           'net', coalesce(pay.amt, 0) - coalesce(ref.amt, 0) - coalesce(voids.amt, 0))
         order by coalesce(pay.amt, 0) desc, pm.display_order), '[]'::jsonb)
    into v_methods
    from public.payment_methods pm
    left join pay on pay.m = pm.id left join ref on ref.m = pm.id left join voids on voids.m = pm.id
   where pm.restaurant_id = v_rest and (pay.m is not null or ref.m is not null or voids.m is not null);

  select coalesce(jsonb_agg(jsonb_build_object(
           'at', p.created_at, 'bill', o.bill_number, 'method', pm.name, 'amount', p.amount,
           'reference', p.reference_no, 'status', p.status, 'by', u.full_name) order by p.created_at), '[]'::jsonb)
    into v_rows
    from public.payments p
    join public.orders o on o.id = p.order_id
    join public.payment_methods pm on pm.id = p.payment_method_id
    left join public.users u on u.id = p.received_by
   where p.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.business_date between p_from and p_to
     and p.status in ('captured', 'refunded');

  return jsonb_build_object('from', p_from, 'to', p_to, 'timezone', v_tz, 'methods', v_methods, 'payments', v_rows);
end $function$;

-- Accounting export: the tax rate in the account name was rounded to a whole number (2.5% showed as "3%").
-- to_char with FM990.### does not keep decimals; write the rate as text with its decimals and drop trailing zeros instead.
do $m$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'accounting_journal' and pg_get_function_identity_arguments(p.oid) = 'p_from date, p_to date';
  v_def := replace(v_def, $a$trim(to_char(t.rate, 'FM990.###'))$a$, $b$rtrim(rtrim(t.rate::numeric(8,3)::text, '0'), '.')$b$);
  v_def := replace(v_def, $a$trim(to_char((t->>'rate')::numeric, 'FM990.###'))$a$, $b$rtrim(rtrim((t->>'rate')::numeric(8,3)::text, '0'), '.')$b$);
  if v_def not like '%rtrim(rtrim(t.rate%' then raise exception 'accounting_journal text not as expected'; end if;
  execute v_def;
end $m$;
