-- 119: Reports follow the business day; reopening a day brings back the cash count.
--
-- Live test 14 Oct: bills made after the night cut-off belong to the next business day, but the sales summary
-- filtered on the calendar date while the GST register / journal / sessions used the business day, so the numbers
-- disagreed. Now the sales summary and day-by-day table use the business day too.
-- Also: "Reopen day" left the automatic shift closed, so the old cash count stayed frozen.
CREATE OR REPLACE FUNCTION public.sales_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_fin boolean;
  v_summary jsonb; v_by_day jsonb; v_by_hour jsonb; v_by_item jsonb; v_by_method jsonb; v_by_type jsonb;
  v_tax jsonb := '[]'::jsonb; v_refunds numeric(14,2); v_refund_count int; v_net numeric(14,2); v_cash_round numeric(14,2);
begin
  perform app.require_permission('report.view_sales');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id();
  v_fin  := app.has_permission('report.view_financial');
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz;
  v_end   := (p_to + 1)::timestamp at time zone v_tz;

  drop table if exists _rep_orders;
  create temp table _rep_orders (id uuid primary key, created_at timestamptz, business_date date, status text,
    order_type text, subtotal numeric, discount_total numeric, tax_total numeric, tax_included numeric,
    service_charge numeric, rounding_adjustment numeric, grand_total numeric, exempt_sales numeric, due numeric, comp_kind text) on commit drop;
  insert into _rep_orders
  select id, created_at, business_date, status, order_type, subtotal, discount_total, tax_total, tax_included,
         service_charge, rounding_adjustment, grand_total, exempt_sales,
         case when status = 'completed' and payment_status in ('unpaid', 'partial')
              then grand_total - app.order_covered(id) else 0 end,
         comp_kind
    from public.orders
   where restaurant_id = v_rest and app.in_scope(branch_id) and business_date between p_from and p_to
     and status in ('completed', 'voided') and merged_into is null;

  select coalesce(sum(r.amount), 0), count(*) into v_refunds, v_refund_count
    from public.refunds r where r.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = r.order_id)) and r.created_at >= v_start and r.created_at < v_end;
  -- Cash-only rounding is kept on the payment, not on the bill: show it, so payments + unpaid = billed + cash rounding.
  select coalesce(sum(p.rounding_adjustment), 0) into v_cash_round
    from public.payments p join _rep_orders o on o.id = p.order_id where p.status = 'captured' and o.status = 'completed';
  select coalesce(sum(oi.net_amount), 0) into v_net
    from public.order_items oi join _rep_orders o on o.id = oi.order_id where o.status = 'completed';

  select jsonb_build_object(
      'bills',          count(*) filter (where status = 'completed' and comp_kind is null),
      'gross_sales',    coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind is null), 0),
      'net_sales',      v_net,
      'discounts',      coalesce(sum(discount_total) filter (where status = 'completed' and comp_kind is null), 0),
      'complimentary_bills', count(*) filter (where status = 'completed' and comp_kind = 'complimentary'),
      'complimentary_value', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'complimentary'), 0),
      'staff_meal_bills',    count(*) filter (where status = 'completed' and comp_kind = 'staff_meal'),
      'staff_meal_value',    coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'staff_meal'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax',            coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included',   coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'exempt_sales',   coalesce(sum(exempt_sales) filter (where status = 'completed'), 0),
      'rounding',       coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'cash_rounding',  v_cash_round,
      'total_billed',   coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'average_bill',   coalesce(round(avg(grand_total) filter (where status = 'completed' and comp_kind is null), 2), 0),
      'voided_bills',   count(*) filter (where status = 'voided'),
      'voided_value',   coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'refunds',        v_refunds,
      'refund_count',   v_refund_count,
      'unpaid_bills',   count(*) filter (where status = 'completed' and due > 0),
      'unpaid_amount',  coalesce(sum(due), 0),
      'net_collected',  coalesce(sum(grand_total) filter (where status = 'completed'), 0) - coalesce(sum(due), 0) - v_refunds + v_cash_round)
    into v_summary from _rep_orders;

  select coalesce(jsonb_agg(jsonb_build_object('day', d, 'bills', n, 'total', t) order by d), '[]'::jsonb) into v_by_day
    from (select business_date d, count(*) n, sum(grand_total) t
            from _rep_orders where status = 'completed' group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('hour', h, 'bills', n, 'total', t) order by h), '[]'::jsonb) into v_by_hour
    from (select extract(hour from created_at at time zone v_tz)::int h, count(*) n, sum(grand_total) t
            from _rep_orders where status = 'completed' group by 1) x;
  select coalesce(jsonb_agg(jsonb_build_object('item', name, 'qty', q, 'amount', a) order by a desc), '[]'::jsonb) into v_by_item
    from (select oi.product_name name, sum(oi.quantity) q, sum(oi.line_subtotal) a
            from public.order_items oi join _rep_orders o on o.id = oi.order_id
           where o.status = 'completed' and oi.cancelled_at is null group by oi.product_name order by 3 desc limit 5000) x;
  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'bills', n, 'amount', a) order by a desc), '[]'::jsonb) into v_by_method
    from (select pm.name, count(*) n, sum(p.amount) a
            from public.payments p join _rep_orders o on o.id = p.order_id
            join public.payment_methods pm on pm.id = p.payment_method_id
           where o.status = 'completed' group by pm.name) x;
  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb) into v_by_type
    from (select order_type, count(*) n, sum(grand_total) t from _rep_orders where status = 'completed' group by 1) x;

  if v_fin then
    select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta) order by r, c), '[]'::jsonb)
      into v_tax
      from (select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
              from public.order_item_taxes t join _rep_orders o on o.id = t.order_id
             where o.status = 'completed' group by 1, 2) x;
  end if;

  return jsonb_build_object('from', p_from, 'to', p_to, 'timezone', v_tz, 'financial', v_fin,
    'summary', v_summary, 'by_day', v_by_day, 'by_hour', v_by_hour, 'by_item', v_by_item,
    'by_method', v_by_method, 'by_type', v_by_type, 'tax', v_tax);
end $function$;

CREATE OR REPLACE FUNCTION public.reopen_day(p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_user uuid := app.require_permission('day.reopen');
  v_branch uuid := app.current_branch_id(); d public.business_days; cur public.business_days; v_list text; v_closed_at timestamptz;
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for reopening the day.'; end if;
  if exists (select 1 from public.business_days where branch_id = v_branch and status = 'parked') then
    raise exception 'A day is already reopened. Close it first.';
  end if;
  select * into d from public.business_days where branch_id = v_branch and status = 'closed'
   order by business_date desc limit 1 for update;
  if not found then raise exception 'There is no closed day to reopen.'; end if;
  select * into cur from public.business_days where branch_id = v_branch and status = 'open' for update;
  if found then
    if cur.business_date < d.business_date then raise exception 'Only the last closed day can be reopened.'; end if;
    select string_agg(bill_number, ', ' order by created_at) into v_list from (
      select o.bill_number, o.created_at from public.orders o
       where o.branch_id = v_branch and o.business_date = cur.business_date and o.status <> 'voided' and o.merged_into is null
       limit 20) x;
    if v_list is null then
      select string_agg(kt.ticket_number, ', ') into v_list from public.kitchen_tickets kt join public.orders o on o.id = kt.order_id
       where o.branch_id = v_branch and o.business_date = cur.business_date and kt.status not in ('cancelled');
    end if;
    if v_list is not null then
      raise exception 'Bills or kitchen tickets have already been made today: %. Void them first, then reopen the day.', v_list;
    end if;
    perform app.close_auto_shifts(v_branch, null); if exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') then
      raise exception 'Close the open shift first, then reopen the day.';
    end if;
    if exists (select 1 from public.orders where branch_id = v_branch and business_date = cur.business_date) then
      update public.business_days set status = 'parked' where id = cur.id;
    else
      delete from public.business_days where id = cur.id;
    end if;
  end if;
  v_closed_at := d.closed_at;
  update public.business_days set status = 'open', closed_at = null, closed_by = null, reopen_count = reopen_count + 1
   where id = d.id;
  -- When shifts are not used, closing the day closed one automatic shift. Open it again, so the cash counted
  -- at closing is asked for again (and the till figure keeps counting) instead of staying frozen at the old count.
  if v_closed_at is not null and not coalesce((select shifts_enabled from public.branch_settings where branch_id = v_branch), false)
     and not exists (select 1 from public.shifts where branch_id = v_branch and status = 'open') then
    update public.shifts set status = 'open', closed_at = null, closed_by = null, expected_cash = null, counted_cash = null, cash_variance = null
     where id = (select id from public.shifts where branch_id = v_branch and status = 'closed' and closed_at = v_closed_at
                  order by opened_at desc limit 1);
  end if;
  perform app.audit('day.reopen', 'business_days', d.id,
    jsonb_build_object('business_date', d.business_date, 'reason', left(trim(p_reason), 300)),
    jsonb_build_object('z_report_total', d.z_report->'total_billed'));
  return jsonb_build_object('business_date', d.business_date);
end $function$;
