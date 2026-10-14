-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260925082616, name 'sna_pos_20_reports_partial_merged_cancelled'. This is the SQL that actually ran.

do $$
declare d text;
begin
  d := pg_get_functiondef('app.shift_figures(uuid)'::regprocedure);
  d := replace(d, $x$payment_status = 'unpaid')$x$, $x$payment_status in ('unpaid', 'partial'))$x$);
  execute d;

  d := pg_get_functiondef('public.sales_report(date, date)'::regprocedure);
  d := replace(d, $x$and status in ('completed', 'voided');$x$, $x$and status in ('completed', 'voided') and merged_into is null;$x$);
  d := replace(d, $x$where o.status = 'completed' group by oi.product_name$x$, $x$where o.status = 'completed' and oi.cancelled_at is null group by oi.product_name$x$);
  execute d;

  if pg_get_functiondef('public.sales_report(date, date)'::regprocedure) not like '%merged_into is null%'
     or pg_get_functiondef('public.sales_report(date, date)'::regprocedure) not like '%oi.cancelled_at is null%'
     or pg_get_functiondef('app.shift_figures(uuid)'::regprocedure) not like '%(''unpaid'', ''partial'')%' then
    raise exception 'patch did not apply';
  end if;
end $$;
