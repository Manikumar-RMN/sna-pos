-- "All outlets" in reports: three reports only ever showed the outlet you were working in.
-- session_report filtered on app.current_branch_id(); No-charge KOT and KOT details read tables directly, where the
-- row-level rule only lets you see your working outlet. They now follow the outlet picker like every other report.

do $m$
declare v_def text;
begin
  select pg_get_functiondef('public.session_report(date,date)'::regprocedure) into v_def;
  v_def := replace(v_def, 'o2.branch_id = app.current_branch_id()', 'o2.restaurant_id = app.current_restaurant_id() and app.in_scope(o2.branch_id)');
  v_def := replace(v_def, 'o.branch_id = app.current_branch_id()', 'o.restaurant_id = app.current_restaurant_id() and app.in_scope(o.branch_id)');
  if v_def like '%current_branch_id()%' then raise exception 'session_report text not as expected'; end if;
  execute v_def;
end $m$;

create or replace function public.report_nc_kot(p_from date, p_to date)
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $f$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_feature('reports_mis');
  perform app.require_permission('report.view_financial');
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'business_date' desc) from (
    select jsonb_build_object('id', o.id, 'bill_number', o.bill_number, 'business_date', o.business_date, 'branch_id', o.branch_id,
      'comp_kind', o.comp_kind, 'comp_reason', o.comp_reason, 'comp_by', o.comp_by, 'comp_charge_to', o.comp_charge_to, 'subtotal', o.subtotal,
      'dining_tables', case when t.id is null then null else jsonb_build_object('table_number', t.table_number) end) x
      from public.orders o left join public.dining_tables t on t.id = o.dining_table_id
     where o.restaurant_id = v_rest and app.in_scope(o.branch_id) and o.comp_kind is not null and o.status <> 'voided'
       and o.business_date between p_from and p_to
     order by o.business_date desc limit 500) z), '[]'::jsonb);
end $f$;

create or replace function public.report_kot_details(p_start timestamptz, p_end timestamptz)
 returns jsonb language plpgsql stable security definer set search_path to 'public', 'pg_temp'
as $f$
declare v_rest uuid := app.current_restaurant_id();
begin
  perform app.require_feature('reports_mis');
  perform app.require_permission('report.view_sales');
  if p_start is null or p_end is null or p_end < p_start or p_end - p_start > interval '367 days' then raise exception 'Choose a range of one year or less.'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'created_at')::timestamptz desc) from (
    select jsonb_build_object('id', k.id, 'ticket_number', k.ticket_number, 'created_at', k.created_at, 'status', k.status, 'station', k.station,
      'cancel_reason', k.cancel_reason, 'branch_id', k.branch_id,
      'orders', case when o.id is null then null else jsonb_build_object('bill_number', o.bill_number,
                  'dining_tables', case when t.id is null then null else jsonb_build_object('table_number', t.table_number) end) end,
      'kitchen_ticket_items', coalesce((select jsonb_agg(jsonb_build_object('product_name', i.product_name, 'quantity', i.quantity, 'status', i.status))
                                          from public.kitchen_ticket_items i where i.kitchen_ticket_id = k.id), '[]'::jsonb)) x
      from public.kitchen_tickets k
      left join public.orders o on o.id = k.order_id
      left join public.dining_tables t on t.id = o.dining_table_id
     where k.restaurant_id = v_rest and app.in_scope(k.branch_id) and k.created_at >= p_start and k.created_at < p_end
     order by k.created_at desc limit 500) z), '[]'::jsonb);
end $f$;

grant execute on function public.report_nc_kot(date, date) to authenticated;
grant execute on function public.report_kot_details(timestamptz, timestamptz) to authenticated;
