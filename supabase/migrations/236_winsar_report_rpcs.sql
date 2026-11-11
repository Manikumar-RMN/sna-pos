-- Winsar parity reports: product-group sales and table-wise sales. Read-only; same rights and outlet scope as the other sales reports.
create or replace function public.report_group_sales(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return coalesce((
    select jsonb_agg(jsonb_build_object('group', x.grp, 'units', x.units, 'amount', x.amount, 'discount', x.disc) order by x.amount desc, x.grp)
      from (
        select coalesce(c.name, 'No group') as grp,
               round(sum(oi.quantity), 2) as units,
               round(sum(oi.line_subtotal), 2) as amount,
               round(sum(coalesce(oi.line_discount, 0)), 2) as disc
          from public.order_items oi
          join public.orders o on o.id = oi.order_id
          left join public.products p on p.id = oi.product_id
          left join public.categories c on c.id = p.category_id
         where o.restaurant_id = v_rest
           and (v_rb is null or o.branch_id = v_rb)
           and o.business_date between p_from and p_to
           and o.status = 'completed' and o.merged_into is null
           and oi.cancelled_at is null
         group by coalesce(c.name, 'No group')) x
  ), '[]'::jsonb);
end $$;

create or replace function public.report_table_sales(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_rb   := app.report_branch();
  return coalesce((
    select jsonb_agg(jsonb_build_object('table', x.tbl, 'bills', x.bills, 'covers', x.covers, 'amount', x.amount) order by x.amount desc, x.tbl)
      from (
        select coalesce(t.table_number, 'No table') as tbl,
               count(*) as bills,
               coalesce(sum(o.covers), 0) as covers,
               round(sum(o.grand_total), 2) as amount
          from public.orders o
          left join public.dining_tables t on t.id = o.dining_table_id
         where o.restaurant_id = v_rest
           and (v_rb is null or o.branch_id = v_rb)
           and o.business_date between p_from and p_to
           and o.status = 'completed' and o.merged_into is null
         group by coalesce(t.table_number, 'No table')) x
  ), '[]'::jsonb);
end $$;

revoke all on function public.report_group_sales(date, date), public.report_table_sales(date, date) from public, anon;
grant execute on function public.report_group_sales(date, date), public.report_table_sales(date, date) to authenticated;
