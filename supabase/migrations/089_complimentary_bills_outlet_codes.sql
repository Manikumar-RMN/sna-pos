-- 089: Complimentary bills and staff meals; outlet codes limited to 3 characters.
--
-- 1. A manager can turn an unpaid bill into a complimentary bill (free for a guest) or a staff
--    meal. The whole bill is taken off, the bill closes at 0.00, and it is marked with its kind,
--    the reason and who approved it. Reports show these bills on their own lines, apart from
--    discounts and sales.
-- 2. Outlet codes are 2 or 3 letters or digits from now on (a GST bill number is at most 16
--    characters). The one 4-character code in use (client 1001, "0111", no bills yet) becomes "011".

alter table public.orders
  add column comp_kind text check (comp_kind in ('complimentary', 'staff_meal')),
  add column comp_reason text check (comp_reason is null or length(comp_reason) between 3 and 200),
  add column comp_by uuid references public.users(id) on delete restrict;
alter table public.orders add constraint orders_comp_complete
  check ((comp_kind is null) = (comp_reason is null) and (comp_kind is null) = (comp_by is null));

create or replace function public.make_complimentary(p_order_id uuid, p_kind text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_user uuid := app.require_permission('order.create');
  o public.orders%rowtype; p jsonb; v_c jsonb; v_reason text := nullif(left(btrim(coalesce(p_reason, '')), 200), '');
  v_label text;
begin
  if p_kind is null or p_kind not in ('complimentary', 'staff_meal') then
    raise exception 'Choose complimentary or staff meal.';
  end if;
  v_label := case p_kind when 'complimentary' then 'complimentary' else 'a staff meal' end;
  if v_reason is null or length(v_reason) < 3 then
    raise exception 'Write a short reason (for example the guest''s name or the staff member''s name).';
  end if;
  select * into o from public.orders where id = p_order_id and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.comp_kind is not null then raise exception 'Bill % is already marked %.', o.bill_number, replace(o.comp_kind, '_', ' '); end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so it cannot be made %.', o.bill_number, v_label;
  end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  if p->'senior' is not null and p->'senior' <> 'null'::jsonb then
    raise exception 'Bill % has a senior citizen / PWD discount. Remove it first.', o.bill_number;
  end if;
  if not exists (select 1 from public.order_items where order_id = o.id and cancelled_at is null) or coalesce(o.subtotal, 0) <= 0 then
    raise exception 'Bill % has no items.', o.bill_number;
  end if;
  if not app.allowed('order.discount') then
    raise exception 'A manager must approve a complimentary bill or staff meal (order.discount).';
  end if;

  -- The whole bill comes off as one discount, the service charge is removed, and the total is worked out again.
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = p || jsonb_build_object('discount', o.subtotal, 'sc_percent', 0) where id = o.id;
  v_c := app.recalc_order(o.id);
  if (v_c->>'grand_total')::numeric <> 0 then
    raise exception 'Bill % could not be brought to zero (total %). Nothing was changed.', o.bill_number, (v_c->>'grand_total')::numeric;
  end if;

  delete from public.order_discounts where order_id = o.id and discount_type = 'fixed_amount';
  insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
  values (o.restaurant_id, o.id, 'fixed_amount', (v_c->>'discount')::numeric, (v_c->>'discount')::numeric,
          left(case p_kind when 'complimentary' then 'Complimentary: ' else 'Staff meal: ' end || v_reason, 200), v_user);

  update public.orders set payment_status = 'paid', comp_kind = p_kind, comp_reason = v_reason, comp_by = v_user
   where id = o.id;

  perform app.audit('order.complimentary', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'kind', p_kind, 'reason', v_reason,
                       'value', o.subtotal, 'grand_total', 0),
    jsonb_build_object('grand_total', o.grand_total, 'discount', coalesce((p->>'discount')::numeric, 0)));
  return jsonb_build_object('order_id', o.id, 'bill_number', o.bill_number, 'kind', p_kind, 'value', o.subtotal, 'grand_total', 0);
end $function$;

revoke all on function public.make_complimentary(uuid, text, text) from public, anon;
grant execute on function public.make_complimentary(uuid, text, text) to authenticated, service_role;

-- Reports: complimentary bills and staff meals on their own lines, outside bills, sales and discounts.
CREATE OR REPLACE FUNCTION public.sales_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_rest uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_fin boolean;
  v_summary jsonb; v_by_day jsonb; v_by_hour jsonb; v_by_item jsonb; v_by_method jsonb; v_by_type jsonb;
  v_tax jsonb := '[]'::jsonb; v_refunds numeric(14,2); v_refund_count int; v_net numeric(14,2);
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
  create temp table _rep_orders (id uuid primary key, created_at timestamptz, status text,
    order_type text, subtotal numeric, discount_total numeric, tax_total numeric, tax_included numeric,
    service_charge numeric, rounding_adjustment numeric, grand_total numeric, exempt_sales numeric, due numeric, comp_kind text) on commit drop;
  insert into _rep_orders
  select id, created_at, status, order_type, subtotal, discount_total, tax_total, tax_included,
         service_charge, rounding_adjustment, grand_total, exempt_sales,
         case when status = 'completed' and payment_status in ('unpaid', 'partial')
              then grand_total - app.order_covered(id) else 0 end,
         comp_kind
    from public.orders
   where restaurant_id = v_rest and app.in_scope(branch_id) and created_at >= v_start and created_at < v_end
     and status in ('completed', 'voided') and merged_into is null;

  select coalesce(sum(r.amount), 0), count(*) into v_refunds, v_refund_count
    from public.refunds r where r.restaurant_id = v_rest and app.in_scope((select o2.branch_id from public.orders o2 where o2.id = r.order_id)) and r.created_at >= v_start and r.created_at < v_end;
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
      'total_billed',   coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'average_bill',   coalesce(round(avg(grand_total) filter (where status = 'completed' and comp_kind is null), 2), 0),
      'voided_bills',   count(*) filter (where status = 'voided'),
      'voided_value',   coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'refunds',        v_refunds,
      'refund_count',   v_refund_count,
      'unpaid_bills',   count(*) filter (where status = 'completed' and due > 0),
      'unpaid_amount',  coalesce(sum(due), 0),
      'net_collected',  coalesce(sum(grand_total) filter (where status = 'completed'), 0) - coalesce(sum(due), 0) - v_refunds)
    into v_summary from _rep_orders;

  select coalesce(jsonb_agg(jsonb_build_object('day', d, 'bills', n, 'total', t) order by d), '[]'::jsonb) into v_by_day
    from (select (created_at at time zone v_tz)::date d, count(*) n, sum(grand_total) t
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

CREATE OR REPLACE FUNCTION app.z_report(p_day uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare d public.business_days; v jsonb; v_pay jsonb; v_tax jsonb; v_cn jsonb; v_shifts jsonb; v_types jsonb;
begin
  select * into d from public.business_days where id = p_day;
  if not found then return null; end if;
  select jsonb_build_object(
      'bills', count(*) filter (where status = 'completed' and comp_kind is null),
      'first_bill', min(bill_number) filter (where status <> 'voided'),
      'last_bill', max(bill_number) filter (where status <> 'voided'),
      'gross_sales', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind is null), 0),
      'discounts', coalesce(sum(discount_total) filter (where status = 'completed' and comp_kind is null), 0),
      'complimentary_bills', count(*) filter (where status = 'completed' and comp_kind = 'complimentary'),
      'complimentary_value', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'complimentary'), 0),
      'staff_meal_bills', count(*) filter (where status = 'completed' and comp_kind = 'staff_meal'),
      'staff_meal_value', coalesce(sum(subtotal) filter (where status = 'completed' and comp_kind = 'staff_meal'), 0),
      'service_charge', coalesce(sum(service_charge) filter (where status = 'completed'), 0),
      'tax', coalesce(sum(tax_total) filter (where status = 'completed'), 0),
      'tax_included', coalesce(sum(tax_included) filter (where status = 'completed'), 0),
      'rounding', coalesce(sum(rounding_adjustment) filter (where status = 'completed'), 0),
      'total_billed', coalesce(sum(grand_total) filter (where status = 'completed'), 0),
      'voided_bills', count(*) filter (where status = 'voided'),
      'voided_value', coalesce(sum(grand_total) filter (where status = 'voided'), 0),
      'unpaid_bills', count(*) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')),
      'unpaid_amount', coalesce(sum(grand_total - app.order_covered(id)) filter (where status = 'completed' and payment_status in ('unpaid', 'partial')), 0))
    into v from public.orders
   where branch_id = d.branch_id and business_date = d.business_date and merged_into is null;

  select coalesce(jsonb_agg(jsonb_build_object('method', name, 'count', n, 'amount', a) order by a desc), '[]'::jsonb)
    into v_pay from (
      select pm.name, count(*) n, sum(p.amount) a from public.payments p
        join public.orders o on o.id = p.order_id join public.payment_methods pm on pm.id = p.payment_method_id
       where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status <> 'voided' and p.status = 'captured'
       group by pm.name) x;
  select coalesce(jsonb_agg(jsonb_build_object('component', c, 'rate', r, 'taxable', tx, 'tax', ta) order by r, c), '[]'::jsonb)
    into v_tax from (
      select t.component_name c, t.rate r, sum(t.taxable_amount) tx, sum(t.tax_amount) ta
        from public.order_item_taxes t join public.orders o on o.id = t.order_id
       where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = 'completed'
       group by 1, 2) x;
  select jsonb_build_object('count', count(*), 'amount', coalesce(sum(amount), 0), 'tax', coalesce(sum(tax_amount), 0),
           'list', coalesce(jsonb_agg(jsonb_build_object('number', number, 'amount', amount, 'bill',
                     (select bill_number from public.orders where id = cn.order_id), 'reason', reason) order by number), '[]'::jsonb))
    into v_cn from public.credit_notes cn where cn.branch_id = d.branch_id and cn.business_date = d.business_date;
  select coalesce(jsonb_agg(app.shift_figures(s.id) order by s.opened_at), '[]'::jsonb) into v_shifts
    from public.shifts s where s.branch_id = d.branch_id
     and exists (select 1 from public.orders o where o.shift_id = s.id and o.business_date = d.business_date
                 union all select 1 from public.payments p join public.orders o on o.id = p.order_id
                  where p.shift_id = s.id and o.business_date = d.business_date);
  select coalesce(jsonb_agg(jsonb_build_object('type', order_type, 'bills', n, 'total', t) order by t desc), '[]'::jsonb) into v_types
    from (select order_type, count(*) n, sum(grand_total) t from public.orders
           where branch_id = d.branch_id and business_date = d.business_date and status = 'completed' and merged_into is null
           group by 1) x;

  return v || jsonb_build_object(
    'business_date', d.business_date, 'branch', (select name from public.branches where id = d.branch_id),
    'status', d.status, 'opened_at', d.opened_at, 'closed_at', d.closed_at,
    'closed_by', (select full_name from public.users where id = d.closed_by),
    'payments', v_pay, 'taxes', v_tax, 'credit_notes', v_cn, 'shifts', v_shifts, 'by_type', v_types, 'sessions', (select coalesce(jsonb_agg(jsonb_build_object('session', sn, 'bills', c, 'total', t) order by first_at), '[]'::jsonb) from (select coalesce(o.session_name, 'Other') sn, count(*) c, sum(o.grand_total) t, min(o.created_at) first_at from public.orders o where o.branch_id = d.branch_id and o.business_date = d.business_date and o.status = 'completed' and o.merged_into is null group by 1) ss),
    'net_sales_after_credit_notes', (v->>'total_billed')::numeric - (v_cn->>'amount')::numeric,
    'reopen_count', d.reopen_count);
end $function$;

CREATE OR REPLACE FUNCTION app.report_summary(p_branch uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  b public.branches%rowtype; r public.restaurants%rowtype; d public.business_days%rowtype;
  z jsonb := '{}'::jsonb; v_items jsonb; v_outlets int;
begin
  select * into b from public.branches where id = p_branch;
  if not found then return null; end if;
  select * into r from public.restaurants where id = b.restaurant_id;
  select count(*) into v_outlets from public.branches where restaurant_id = b.restaurant_id and deleted_at is null;

  select * into d from public.business_days where branch_id = p_branch and business_date = p_date;
  if found then
    -- A closed day keeps the report saved when it closed, exactly as the Day report screen shows it.
    z := case when d.status = 'closed' and d.z_report is not null then d.z_report else app.z_report(d.id) end;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('item', x.name, 'qty', x.q, 'amount', x.a) order by x.a desc, x.name), '[]'::jsonb)
    into v_items
    from (select oi.product_name as name, sum(oi.quantity) as q, sum(oi.line_subtotal) as a
            from public.order_items oi
            join public.orders o on o.id = oi.order_id
            left join public.products p on p.id = oi.product_id
           where o.branch_id = p_branch and o.business_date = p_date and o.status = 'completed'
             and o.merged_into is null and oi.cancelled_at is null and not coalesce(p.is_charge, false)
           group by oi.product_name
           order by 3 desc, 1
           limit 5) x;

  return jsonb_build_object(
    'restaurant', r.trading_name, 'outlet', b.name, 'several_outlets', v_outlets > 1,
    'currency', r.currency_code, 'business_date', p_date,
    'day_status', coalesce(d.status, 'none'),
    'bills', coalesce((z->>'bills')::int, 0),
    'total_billed', coalesce((z->>'total_billed')::numeric, 0),
    'discounts', coalesce((z->>'discounts')::numeric, 0),
    'complimentary_bills', coalesce((z->>'complimentary_bills')::int, 0),
    'complimentary_value', coalesce((z->>'complimentary_value')::numeric, 0),
    'staff_meal_bills', coalesce((z->>'staff_meal_bills')::int, 0),
    'staff_meal_value', coalesce((z->>'staff_meal_value')::numeric, 0),
    'tax', coalesce((z->>'tax')::numeric, 0),
    'service_charge', coalesce((z->>'service_charge')::numeric, 0),
    'voided_bills', coalesce((z->>'voided_bills')::int, 0),
    'voided_value', coalesce((z->>'voided_value')::numeric, 0),
    'unpaid_bills', coalesce((z->>'unpaid_bills')::int, 0),
    'unpaid_amount', coalesce((z->>'unpaid_amount')::numeric, 0),
    'refunds', coalesce((z->'credit_notes'->>'amount')::numeric, 0),
    'refund_count', coalesce((z->'credit_notes'->>'count')::int, 0),
    'payments', coalesce(z->'payments', '[]'::jsonb),
    'by_type', coalesce(z->'by_type', '[]'::jsonb),
    'top_items', v_items);
end $function$;

-- Outlet codes: 2 or 3 characters.
CREATE OR REPLACE FUNCTION public.sna_create_outlet(p_request uuid, p_name text, p_code text, p_city text, p_address text DEFAULT NULL::text, p_phone text DEFAULT NULL::text, p_timezone text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare q public.plan_requests%rowtype; v_rest public.restaurants%rowtype; v_first public.branches%rowtype; v_id uuid;
begin
  perform app.sna_require(array['implementer']);
  select * into q from public.plan_requests where id = p_request for update;
  if not found or q.kind <> 'outlet' then raise exception 'Outlet request not found.'; end if;
  if q.status <> 'approved' then raise exception 'Sales must approve this outlet before it is added.'; end if;
  select * into v_rest from public.restaurants where id = q.restaurant_id;
  if v_rest.edition <> 'professional' then raise exception 'Upgrade the restaurant to Professional before adding outlets.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the outlet name.'; end if;
  if coalesce(trim(p_code), '') !~ '^[A-Za-z0-9]{2,3}$' then raise exception 'The outlet code is 2 or 3 letters or digits (it starts every bill number, and a GST bill number can be at most 16 characters).'; end if;
  if exists (select 1 from public.branches where restaurant_id = q.restaurant_id and upper(code) = upper(trim(p_code)) and deleted_at is null) then
    raise exception 'Another outlet already uses the code %.', upper(trim(p_code));
  end if;
  select * into v_first from public.branches where restaurant_id = q.restaurant_id and deleted_at is null order by created_at limit 1;
  insert into public.branches (restaurant_id, name, code, address_line1, city, country_code, phone, timezone, is_active)
  values (q.restaurant_id, left(trim(p_name), 80), upper(trim(p_code)), nullif(trim(p_address), ''), nullif(trim(p_city), ''),
          v_rest.country_code, nullif(trim(p_phone), ''), coalesce(nullif(p_timezone, ''), v_first.timezone, v_rest.timezone), true)
  returning id into v_id;
  insert into public.branch_settings (branch_id, restaurant_id, receipt_header, receipt_footer, service_charge_percent, cash_rounding_mode,
      default_order_type, auto_print_kot, service_charge_taxable, service_charge_default_on, service_charge_label, rounding_cash_only)
  select v_id, s.restaurant_id, s.receipt_header, s.receipt_footer, s.service_charge_percent, s.cash_rounding_mode,
         s.default_order_type, s.auto_print_kot, s.service_charge_taxable, s.service_charge_default_on, s.service_charge_label, s.rounding_cash_only
    from public.branch_settings s where s.branch_id = v_first.id;
  if not found then
    insert into public.branch_settings (branch_id, restaurant_id) values (v_id, q.restaurant_id);
  end if;
  insert into public.devices (restaurant_id, branch_id, name, device_type, bill_prefix)
  values (q.restaurant_id, v_id, 'Counter 1', 'tablet', 'C1');
  insert into public.user_branches (user_id, branch_id, restaurant_id)
  select u.id, v_id, q.restaurant_id from public.users u join public.roles r on r.id = u.role_id
   where u.restaurant_id = q.restaurant_id and r.name = 'Owner' and r.is_system and u.deleted_at is null
  on conflict do nothing;
  update public.plan_requests set status = 'done', done_by = app.sna_staff_id(), done_at = now(), branch_id = v_id where id = p_request;
  perform app.log_plan(q.restaurant_id, 'outlet.created', jsonb_build_object('request', p_request, 'branch', v_id, 'name', p_name, 'code', upper(trim(p_code))));
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.sna_create_client(p_owner_email text, p_owner_name text, p_legal_name text, p_trading_name text, p_country_code text, p_temp_password text, p_branch_name text DEFAULT 'Main Branch'::text, p_branch_code text DEFAULT 'MN'::text, p_tax_registration_no text DEFAULT NULL::text, p_edition text DEFAULT 'basic'::text, p_licence_start date DEFAULT NULL::date, p_licence_expiry date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_me uuid; v_auth uuid; v_rest uuid; v_hash text; v_is_sna boolean;
  v_email text := lower(trim(coalesce(p_owner_email, '')));
  v_owner text := trim(coalesce(p_owner_name, ''));
  v_legal text := trim(coalesce(p_legal_name, ''));
  v_trading text := trim(coalesce(p_trading_name, ''));
  v_branch text := coalesce(nullif(trim(coalesce(p_branch_name, '')), ''), 'Main Branch');
  v_code text := upper(coalesce(nullif(trim(coalesce(p_branch_code, '')), ''), 'MN'));
  v_claims text; v_sub text;
begin
  v_me := app.sna_require(array['sales', 'implementer', 'support']);
  -- Edition and licence dates are a sales matter, as they are on the client page.
  if coalesce(p_edition, 'basic') <> 'basic' or p_licence_start is not null or p_licence_expiry is not null then
    perform app.sna_require(array['sales']);
  end if;
  if coalesce(p_edition, 'basic') not in ('basic', 'professional') then raise exception 'Unknown edition.'; end if;
  if p_licence_start is not null and p_licence_expiry is not null and p_licence_expiry < p_licence_start then
    raise exception 'The licence cannot end before it starts.';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or length(v_email) > 200 then raise exception 'Enter the owner''s email address.'; end if;
  if length(v_owner) = 0 or length(v_legal) = 0 or length(v_trading) = 0 then raise exception 'Fill in the business name, the display name and the owner''s name.'; end if;
  if length(v_owner) > 120 or length(v_legal) > 200 or length(v_trading) > 200 or length(v_branch) > 120 then raise exception 'One of the names is too long.'; end if;
  if v_code !~ '^[A-Z0-9]{2,3}$' then raise exception 'The outlet code is 2 or 3 letters or digits, for example MN (a GST bill number can be at most 16 characters).'; end if;

  select id into v_auth from auth.users where lower(email) = v_email;
  if v_auth is null then raise exception 'The sign-in for % could not be made. Try again.', v_email; end if;
  if exists (select 1 from public.devices where auth_user_id = v_auth) then raise exception 'That email belongs to a counter tablet.'; end if;
  if exists (select 1 from public.users where auth_user_id = v_auth and deleted_at is null) then
    raise exception '% already belongs to a restaurant. Use a different email for this owner.', v_email;
  end if;
  v_is_sna := exists (select 1 from public.sna_staff where auth_user_id = v_auth);

  -- The owner gets the temporary password SNA hands over, whoever made the sign-in and whenever:
  -- an address someone else registered first must not keep that person's password.
  -- An SNA staff member testing with their own address keeps their own password.
  if not v_is_sna then
    if length(coalesce(p_temp_password, '')) < 8 or length(p_temp_password) > 72 then raise exception 'The temporary password must be 8 to 72 characters.'; end if;
    v_hash := extensions.crypt(p_temp_password, extensions.gen_salt('bf', 10));
    update auth.users set encrypted_password = v_hash, email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now() where id = v_auth;
    delete from auth.sessions where user_id = v_auth;
  end if;

  -- Build the restaurant exactly as a sign-up always has: as the owner, for this one call.
  v_claims := current_setting('request.jwt.claims', true);
  v_sub := current_setting('request.jwt.claim.sub', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_auth, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_auth::text, true);
  v_rest := app.create_restaurant_with_owner(v_legal, v_trading, p_country_code::character(2), v_owner, v_branch, v_code, null, p_tax_registration_no);
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
  if app.sna_staff_id() is distinct from v_me then raise exception 'Could not finish creating the client.'; end if;

  if p_edition = 'professional' then update public.restaurants set edition = 'professional' where id = v_rest; end if;
  update public.restaurants set subscription_status = 'active' where id = v_rest;
  insert into public.sna_accounts (restaurant_id, licence_start, licence_expiry, updated_by)
  values (v_rest, p_licence_start, p_licence_expiry, v_me);
  if not v_is_sna then
    update public.users set must_change_password = true, password_reset_hash = v_hash where restaurant_id = v_rest and auth_user_id = v_auth;
  end if;
  perform app.log_plan(v_rest, 'client.created', jsonb_strip_nulls(jsonb_build_object(
    'owner', v_email, 'edition', coalesce(p_edition, 'basic'), 'licence_start', p_licence_start, 'licence_expiry', p_licence_expiry)));

  return jsonb_build_object('id', v_rest, 'client_code', (select client_code from public.restaurants where id = v_rest),
                            'owner_email', v_email, 'kept_password', v_is_sna);
end $function$;

update public.branches set code = '011'
 where code = '0111' and id = '1187bb85-5667-4439-aa49-d27590642d86'
   and not exists (select 1 from public.orders o where o.branch_id = '1187bb85-5667-4439-aa49-d27590642d86')
   and not exists (select 1 from public.branches b2 where b2.restaurant_id = branches.restaurant_id and b2.code = '011');
