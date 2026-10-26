-- 145: customers + loyalty delta (the customer list, history, regular-guest lookup, privacy, and points redeemed as a DISCOUNT on the bill).
--
-- What already exists (064, 100, 116, 120): customers created from the bill phone, loyalty_settings / loyalty_ledger, earn / reverse / void return,
-- redeem_points (a PAYMENT with method kind 'loyalty'). This file adds, without touching those tables' data:
--   1. Rights customer.view ("See the customer list and history") and loyalty.redeem ("Use loyalty points on a bill"). Granted by this migration to the
--      system roles Owner, Manager, Cashier (loyalty.redeem) and to Owner, Manager, Cashier + every role that has customer.manage (customer.view).
--      New restaurants: 148 patches create_restaurant_with_owner. customer.manage keeps implying read (Waiter keeps working); it is NOT removed from anyone.
--   2. Privacy: the customers and loyalty_ledger tables are readable only with customer.view or customer.manage (they were readable by every signed-in user,
--      phone numbers included). Anything a role without these rights needs goes through definer functions (attach_customer, set_order_guest, create_order, find_customer).
--   3. Derived stats (never stored): visit = a bill with customer_id, payment_status 'paid' or 'partially_refunded' (a part refund is still a visit; a full refund is not), status <> 'voided', not merged away; spend = sum(grand_total) minus the
--      bill's credit notes; first/last visit by business_date. public.customer_list / customer_detail / find_customer / update_customer / forget_customer.
--   4. loyalty_settings.redeem_mode ('tender' = the old payment, default so nobody changes silently; 'discount' = pre-tax bill discount) and max_redeem_percent
--      (default 100); ledger kind 'expire' is allowed (no expiry job yet: points do not expire); save_loyalty_settings gets a 5-argument overload.
--   5. public.redeem_points_discount / remove_points_discount: the points become calc_params.loyalty_discount / loyalty_points, spread by app.calc_bill (141)
--      over the discountable lines BEFORE tax, so the taxable value falls by the discount. Same safety rules as adjust_order: only an unpaid bill with no payment.
--      The old redeem_points refuses when the mode is 'discount'.
-- GST note (plan 4.4, to be confirmed by the tax adviser before a GST restaurant uses mode 'discount'): points count as a pre-supply discount only if the scheme is
-- known in advance and the discount is shown on the invoice (s.15(3)(a)); 'tender' keeps GST on the full value. Hence the setting.
-- Additive: columns with defaults, policies replaced, new functions. Re-runnable.

-- ---------------------------------------------------------------- 1. rights
insert into public.permissions (key, description, is_sensitive) values
  ('customer.view', 'See the customer list and history', true),
  ('loyalty.redeem', 'Use loyalty points on a bill', true)
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_key)
select r.id, 'customer.view' from public.roles r
 where (r.is_system and r.name in ('Owner', 'Manager', 'Cashier'))
    or exists (select 1 from public.role_permissions rp where rp.role_id = r.id and rp.permission_key = 'customer.manage')
on conflict do nothing;
insert into public.role_permissions (role_id, permission_key)
select r.id, 'loyalty.redeem' from public.roles r
 where r.is_system and r.name in ('Owner', 'Manager', 'Cashier')
on conflict do nothing;

-- ---------------------------------------------------------------- 2. privacy (read access)
drop policy if exists tenant_read on public.customers;
create policy tenant_read on public.customers for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id())
         and ((select app.has_permission('customer.view')) or (select app.has_permission('customer.manage'))));
drop policy if exists tenant_read on public.loyalty_ledger;
create policy tenant_read on public.loyalty_ledger for select to authenticated
  using (restaurant_id = (select app.current_restaurant_id())
         and ((select app.has_permission('customer.view')) or (select app.has_permission('customer.manage'))));

-- ---------------------------------------------------------------- indexes
create index if not exists orders_customer_paid_idx on public.orders (customer_id, business_date) where customer_id is not null;
create index if not exists customers_phone10_idx on public.customers (restaurant_id, (right(regexp_replace(phone, '[^0-9]', '', 'g'), 10)))
  where deleted_at is null and phone is not null;

-- ---------------------------------------------------------------- 4. settings
alter table public.loyalty_settings add column if not exists redeem_mode text not null default 'tender';
alter table public.loyalty_settings add column if not exists max_redeem_percent numeric(5,2) not null default 100;
alter table public.loyalty_settings drop constraint if exists loyalty_settings_redeem_mode_check;
alter table public.loyalty_settings add constraint loyalty_settings_redeem_mode_check check (redeem_mode in ('tender', 'discount'));
alter table public.loyalty_settings drop constraint if exists loyalty_settings_max_redeem_percent_check;
alter table public.loyalty_settings add constraint loyalty_settings_max_redeem_percent_check check (max_redeem_percent between 1 and 100);
alter table public.loyalty_ledger drop constraint if exists loyalty_ledger_kind_check;
alter table public.loyalty_ledger add constraint loyalty_ledger_kind_check check (kind in ('earn', 'redeem', 'reverse', 'adjust', 'expire'));

-- Same name, five arguments; the three-argument one (064) stays and keeps the current mode and cap.
create or replace function public.save_loyalty_settings(p_spend_per_point numeric, p_point_value numeric, p_min_redeem int, p_mode text, p_max_percent numeric)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_old public.loyalty_settings%rowtype;
begin
  perform app.require_permission('settings.manage');
  perform app.require_feature('loyalty');
  if p_mode is null or p_mode not in ('tender', 'discount') then raise exception 'Choose how points are redeemed: as a discount on the bill or as a payment.'; end if;
  if p_max_percent is null or p_max_percent < 1 or p_max_percent > 100 then raise exception 'The highest share of a bill points can pay must be between 1 and 100 percent.'; end if;
  if p_spend_per_point is null or p_spend_per_point <= 0 then raise exception 'Rupees spent for 1 point must be more than zero.'; end if;
  if p_point_value is null or p_point_value < 0 then raise exception 'The value of a point cannot be negative.'; end if;
  select * into v_old from public.loyalty_settings where restaurant_id = app.current_restaurant_id();
  insert into public.loyalty_settings (restaurant_id, spend_per_point, point_value, min_redeem, redeem_mode, max_redeem_percent)
  values (app.current_restaurant_id(), p_spend_per_point, p_point_value, greatest(coalesce(p_min_redeem, 0), 0), p_mode, round(p_max_percent, 2))
  on conflict (restaurant_id) do update set spend_per_point = excluded.spend_per_point, point_value = excluded.point_value,
    min_redeem = excluded.min_redeem, redeem_mode = excluded.redeem_mode, max_redeem_percent = excluded.max_redeem_percent, updated_at = now();
  perform app.audit('loyalty.settings', 'loyalty_settings', null,
    jsonb_build_object('spend_per_point', p_spend_per_point, 'point_value', p_point_value, 'min_redeem', coalesce(p_min_redeem, 0), 'redeem_mode', p_mode, 'max_redeem_percent', p_max_percent),
    case when v_old.restaurant_id is null then null else jsonb_build_object('spend_per_point', v_old.spend_per_point, 'point_value', v_old.point_value, 'min_redeem', v_old.min_redeem,
         'redeem_mode', v_old.redeem_mode, 'max_redeem_percent', v_old.max_redeem_percent) end);
end $$;

-- ---------------------------------------------------------------- tender redeem refuses in discount mode (064 body + one check)
CREATE OR REPLACE FUNCTION public.redeem_points(p_order uuid, p_points numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare o public.orders%rowtype; s public.loyalty_settings%rowtype; v_bal numeric; v_due numeric; v_amt numeric; v_pts numeric; v_res jsonb;
begin
  perform app.require_permission('payment.take');
  perform app.require_feature('loyalty');
  select * into o from public.orders where id = p_order and restaurant_id = app.current_restaurant_id() for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.customer_id is null then raise exception 'Add the guest''s phone number to the bill first.'; end if;
  select * into s from public.loyalty_settings where restaurant_id = o.restaurant_id;
  if not found or s.point_value <= 0 then raise exception 'Set up loyalty points in Settings first.'; end if;
  -- 145: an outlet set to redeem points as a discount on the bill (before tax) uses redeem_points_discount instead.
  if s.redeem_mode = 'discount' then raise exception 'This outlet redeems points as a discount on the bill.'; end if;
  perform pg_advisory_xact_lock(hashtext('points:' || o.customer_id::text));
  v_bal := app.points_balance(o.customer_id);
  v_pts := floor(coalesce(p_points, 0));
  if v_pts <= 0 then raise exception 'Enter the points to use.'; end if;
  if v_pts > v_bal then raise exception 'The guest has only % points.', v_bal; end if;
  if v_pts < s.min_redeem then raise exception 'At least % points must be used at a time.', s.min_redeem; end if;
  v_due := o.grand_total - app.order_covered(o.id);
  v_amt := round(v_pts * s.point_value, 2);
  if v_amt > v_due then
    v_amt := v_due;
    v_pts := ceil(v_amt / s.point_value);
  end if;
  if v_amt <= 0 then raise exception 'Nothing left to pay on this bill.'; end if;
  perform set_config('app.redeem', 'on', true);
  v_res := public.pay_order(o.id, app.system_method(o.restaurant_id, 'loyalty'), null, v_amt, v_pts || ' points', null);
  perform set_config('app.redeem', '', true);
  insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note, created_by)
  values (o.restaurant_id, o.customer_id, o.id, -v_pts, 'redeem', 'Bill ' || o.bill_number, app.current_user_id());
  return v_res || jsonb_build_object('points_used', v_pts, 'points_left', v_bal - v_pts);
end $function$;

-- ---------------------------------------------------------------- 5. redeem as a discount
create or replace function public.redeem_points_discount(p_order uuid, p_points numeric, p_client_ref uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid; v_rest uuid := app.current_restaurant_id(); o public.orders%rowtype; s public.loyalty_settings%rowtype; p jsonb;
  v_seen record; v_bal numeric; v_pts numeric; v_rs numeric; v_pool numeric; v_manual numeric; v_cap numeric; v_due numeric; v_c jsonb; v_out jsonb;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  perform app.require_feature('loyalty');
  v_user := app.require_permission('loyalty.redeem');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('ref:' || p_client_ref::text));
    select rr.result, rr.kind, rr.order_id into v_seen from public.request_refs rr where rr.restaurant_id = v_rest and rr.ref = p_client_ref;
    if found then
      if v_seen.kind <> 'loyalty_redeem' or v_seen.order_id is distinct from p_order then
        raise exception 'This request was already used for something else. Go back, open the bill again and try once more.';
      end if;
      return v_seen.result || jsonb_build_object('repeat', true);
    end if;
  end if;
  select * into o from public.orders where id = p_order and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so points cannot be used as a discount on it.', o.bill_number;
  end if;
  if o.customer_id is null then raise exception 'Add the guest''s phone number to the bill first.'; end if;
  select * into s from public.loyalty_settings where restaurant_id = v_rest;
  if not found or s.point_value <= 0 then raise exception 'Set up loyalty points in Settings first.'; end if;
  if s.redeem_mode <> 'discount' then raise exception 'This outlet redeems points as a payment, not as a discount.'; end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  if p->'senior' is not null and p->'senior' <> 'null'::jsonb then
    raise exception 'This bill has a senior citizen / PWD discount; points cannot be used on it.';
  end if;
  if coalesce((p->>'loyalty_points')::numeric, 0) > 0 then
    raise exception 'Points are already used on this bill. Remove them first to use a different amount.';
  end if;
  perform pg_advisory_xact_lock(hashtext('points:' || o.customer_id::text));
  v_bal := app.points_balance(o.customer_id);
  v_pts := floor(coalesce(p_points, 0));
  if v_pts <= 0 then raise exception 'Enter the points to use.'; end if;
  if v_pts > v_bal then raise exception 'The guest has only % points.', v_bal; end if;
  if v_pts < s.min_redeem then raise exception 'At least % points must be used at a time.', s.min_redeem; end if;
  v_rs := round(v_pts * s.point_value, 2);
  -- What the points may take: the share allowed (max_redeem_percent) of the discountable lines, less the typed discount, and never more than is due.
  select coalesce(sum(i.line_subtotal) filter (where not i.discount_blocked), 0) into v_pool
    from public.order_items i where i.order_id = o.id and i.cancelled_at is null;
  v_manual := least(coalesce((p->>'discount')::numeric, 0), v_pool);
  v_cap := round((v_pool - v_manual) * s.max_redeem_percent / 100, 2);
  v_due := o.grand_total;
  if v_rs > least(v_cap, v_due) then
    v_rs := least(v_cap, v_due);
    v_pts := ceil(v_rs / s.point_value);
  end if;
  if v_rs <= 0 then raise exception 'Nothing on this bill can be discounted with points.'; end if;
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = p || jsonb_build_object('loyalty_discount', v_rs, 'loyalty_points', v_pts) where id = o.id;
  v_c := app.recalc_order(o.id);
  if (v_c->>'loyalty_discount')::numeric <> v_rs then
    raise exception 'The points discount could not be applied in full. Nothing was changed.';
  end if;
  insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note, created_by)
  values (v_rest, o.customer_id, o.id, -v_pts, 'redeem', 'Bill ' || o.bill_number, v_user);
  insert into public.order_discounts (restaurant_id, order_id, discount_type, value, amount, reason, approved_by)
  values (v_rest, o.id, 'loyalty_points', v_pts, v_rs, 'Loyalty points', v_user);
  perform app.audit('loyalty.redeem_discount', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'customer_id', o.customer_id, 'points', v_pts, 'amount', v_rs, 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', o.grand_total));
  v_out := jsonb_build_object('points_used', v_pts, 'discount', v_rs, 'grand_total', (v_c->>'grand_total')::numeric, 'points_left', v_bal - v_pts);
  if p_client_ref is not null then
    insert into public.request_refs (restaurant_id, ref, kind, order_id, result) values (v_rest, p_client_ref, 'loyalty_redeem', o.id, v_out);
    delete from public.request_refs where restaurant_id = v_rest and created_at < now() - interval '7 days';
  end if;
  return v_out;
end $$;

create or replace function public.remove_points_discount(p_order uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid; v_rest uuid := app.current_restaurant_id(); o public.orders%rowtype; p jsonb; v_pts numeric; v_c jsonb; v_cust uuid;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  perform app.require_feature('loyalty');
  v_user := app.require_permission('loyalty.redeem');
  select * into o from public.orders where id = p_order and restaurant_id = v_rest for update;
  if not found then raise exception 'Bill not found.'; end if;
  if o.status = 'voided' then raise exception 'Bill % is voided.', o.bill_number; end if;
  if o.merged_into is not null then raise exception 'Bill % was merged into another bill.', o.bill_number; end if;
  if o.payment_status <> 'unpaid' or app.order_covered(o.id) > 0 then
    raise exception 'Bill % already has a payment, so the points discount cannot be changed.', o.bill_number;
  end if;
  p := coalesce(o.calc_params, '{}'::jsonb);
  v_pts := coalesce((p->>'loyalty_points')::numeric, 0);
  if v_pts <= 0 then raise exception 'No points have been used on this bill.'; end if;
  -- QA fix: the points go back to the guest who spent them (the redeem row), not to whoever is on the bill now.
  select l.customer_id into v_cust from public.loyalty_ledger l where l.order_id = o.id and l.kind = 'redeem' order by l.created_at desc, l.id desc limit 1;
  v_cust := coalesce(v_cust, o.customer_id);
  if v_cust is not null then perform pg_advisory_xact_lock(hashtext('points:' || v_cust::text)); end if;
  perform set_config('app.recalc', 'on', true);
  update public.orders set calc_params = (p - 'loyalty_discount') - 'loyalty_points' where id = o.id;
  v_c := app.recalc_order(o.id);
  delete from public.order_discounts where order_id = o.id and discount_type = 'loyalty_points';
  if v_cust is not null then
    insert into public.loyalty_ledger (restaurant_id, customer_id, order_id, points, kind, note, created_by)
    values (v_rest, v_cust, o.id, v_pts, 'adjust', 'Redeem removed', v_user);
  end if;
  perform app.audit('loyalty.redeem_removed', 'orders', o.id,
    jsonb_build_object('bill_number', o.bill_number, 'customer_id', o.customer_id, 'points', v_pts, 'grand_total', (v_c->>'grand_total')::numeric),
    jsonb_build_object('grand_total', o.grand_total, 'amount', coalesce((p->>'loyalty_discount')::numeric, 0)));
  return jsonb_build_object('points_returned', v_pts, 'grand_total', (v_c->>'grand_total')::numeric,
                            'points_left', case when v_cust is null then 0 else app.points_balance(v_cust) end);
end $$;

-- ---------------------------------------------------------------- 3. customer list / detail / lookup / edit / forget
-- Visits and spend are counted for app.report_branch() (null = every outlet); the customer record itself is restaurant-wide.
create or replace function public.customer_list(p_q text default null, p_filter text default 'all', p_sort text default 'last_visit',
                                                p_limit int default 50, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_rb uuid; v_q text := nullif(trim(coalesce(p_q, '')), ''); v_digits text; v_today date;
        v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200); v_off int := greatest(coalesce(p_offset, 0), 0); v_like text;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if not (app.has_permission('customer.view') or app.has_permission('customer.manage')) then
    raise exception 'Your role does not allow this action (customer.view).';
  end if;
  if coalesce(p_filter, 'all') not in ('all', 'repeat', 'new', 'lapsed', 'never') then raise exception 'Unknown filter.'; end if;
  if coalesce(p_sort, 'last_visit') not in ('last_visit', 'spend', 'visits', 'points', 'name') then raise exception 'Unknown sort.'; end if;
  v_rb := app.report_branch();
  v_today := app.local_today(v_rest);
  -- A search needs at least 3 characters; shorter text is ignored (the list is not filtered).
  if v_q is not null and length(v_q) < 3 then v_q := null; end if;
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  v_like := '%' || replace(replace(replace(coalesce(v_q, ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return (
    with st as (
      select o.customer_id, count(*) as visits,
             coalesce(sum(o.grand_total), 0) - coalesce(sum((select sum(cn.amount) from public.credit_notes cn where cn.order_id = o.id)), 0) as net,
             min(o.business_date) as first_on, max(o.business_date) as last_on
        from public.orders o
       where o.restaurant_id = v_rest and o.customer_id is not null and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null
         and (v_rb is null or o.branch_id = v_rb)
       group by o.customer_id),
    pts as (select l.customer_id, sum(l.points) as bal from public.loyalty_ledger l where l.restaurant_id = v_rest group by l.customer_id),
    b as (
      select c.id, c.name, c.phone, coalesce(st.visits, 0)::int as visits, coalesce(st.net, 0) as spend,
             case when coalesce(st.visits, 0) > 0 then round(st.net / st.visits, 2) else 0 end as avg_bill,
             st.first_on as first_visit_on, st.last_on as last_visit_on, coalesce(pts.bal, 0) as points, c.marketing_consent
        from public.customers c
        left join st on st.customer_id = c.id
        left join pts on pts.customer_id = c.id
       where c.restaurant_id = v_rest and c.deleted_at is null
         and (v_q is null or c.name ilike v_like or (length(v_digits) >= 3 and regexp_replace(coalesce(c.phone, ''), '[^0-9]', '', 'g') like '%' || v_digits || '%'))
         and case coalesce(p_filter, 'all')
               when 'repeat' then coalesce(st.visits, 0) >= 2
               when 'new'    then coalesce(st.visits, 0) = 1
               when 'lapsed' then coalesce(st.visits, 0) >= 1 and st.last_on < v_today - 60
               when 'never'  then coalesce(st.visits, 0) = 0
               else true end),
    r as (
      select b.*, row_number() over (order by
               case when coalesce(p_sort, 'last_visit') = 'last_visit' then b.last_visit_on end desc nulls last,
               case when p_sort = 'spend'  then b.spend end desc,
               case when p_sort = 'visits' then b.visits end desc,
               case when p_sort = 'points' then b.points end desc,
               lower(coalesce(b.name, '')), b.id) as rn
        from b)
    select jsonb_build_object(
      'total', (select count(*) from b),
      'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'phone', r.phone, 'visits', r.visits, 'spend', r.spend,
                 'avg_bill', r.avg_bill, 'first_visit_on', r.first_visit_on, 'last_visit_on', r.last_visit_on, 'points', r.points,
                 'marketing_consent', r.marketing_consent) order by r.rn)
                 from r where r.rn > v_off and r.rn <= v_off + v_lim), '[]'::jsonb))
  );
end $$;

create or replace function public.customer_detail(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_rb uuid; c public.customers%rowtype; v_stats jsonb;
begin
  if v_rest is null then raise exception 'You are not signed in to a restaurant.'; end if;
  if not (app.has_permission('customer.view') or app.has_permission('customer.manage')) then
    raise exception 'Your role does not allow this action (customer.view).';
  end if;
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest;
  if not found then raise exception 'Customer not found.'; end if;
  v_rb := app.report_branch();
  select jsonb_build_object('visits', count(*),
           'spend', coalesce(sum(o.grand_total), 0) - coalesce(sum((select sum(cn.amount) from public.credit_notes cn where cn.order_id = o.id)), 0),
           'first_visit_on', min(o.business_date), 'last_visit_on', max(o.business_date))
    into v_stats
    from public.orders o
   where o.restaurant_id = v_rest and o.customer_id = c.id and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null
     and (v_rb is null or o.branch_id = v_rb);
  v_stats := v_stats || jsonb_build_object('avg_bill',
    case when (v_stats->>'visits')::int > 0 then round((v_stats->>'spend')::numeric / (v_stats->>'visits')::int, 2) else 0 end);
  return jsonb_build_object(
    'profile', jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'email', c.email, 'notes', c.notes, 'date_of_birth', c.date_of_birth,
                'marketing_consent', c.marketing_consent, 'consent_given_at', c.consent_given_at, 'created_at', c.created_at,
                'credit_limit', c.credit_limit, 'account_company', c.account_company),
    'stats', v_stats,
    'points_balance', app.points_balance(c.id), 'points_expire', false, 'points_note', 'Points do not expire.',
    'account_balance', app.account_balance(c.id),
    'bills', coalesce((
      select jsonb_agg(q.x order by q.sort_d desc, q.sort_t desc)
        from (select jsonb_build_object('id', o.id, 'bill_number', o.bill_number, 'business_date', o.business_date, 'outlet', coalesce(b.name, ''),
                       'total', o.grand_total, 'status', o.status, 'payment_status', o.payment_status,
                       'is_visit', (o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided'),
                       'refunded', coalesce((select sum(cn.amount) from public.credit_notes cn where cn.order_id = o.id), 0),
                       'payment_mode', (select string_agg(distinct pm.name, ', ') from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id
                                         where p.order_id = o.id and p.status = 'captured'),
                       'points_earned', coalesce((select sum(l.points) from public.loyalty_ledger l where l.order_id = o.id and l.kind = 'earn'), 0),
                       'points_redeemed', coalesce(-(select sum(l.points) from public.loyalty_ledger l where l.order_id = o.id and l.kind = 'redeem'), 0)) as x,
                     o.business_date as sort_d, o.created_at as sort_t
                from public.orders o left join public.branches b on b.id = o.branch_id
               where o.restaurant_id = v_rest and o.customer_id = c.id and o.merged_into is null and (v_rb is null or o.branch_id = v_rb)
               order by o.business_date desc, o.created_at desc limit 50) q), '[]'::jsonb),
    'ledger', coalesce((
      select jsonb_agg(q.x order by q.sort_t desc)
        from (select jsonb_build_object('id', l.id, 'at', l.created_at, 'kind', l.kind, 'points', l.points, 'note', l.note, 'bill_number', o.bill_number) as x, l.created_at as sort_t
                from public.loyalty_ledger l left join public.orders o on o.id = l.order_id
               where l.customer_id = c.id and l.restaurant_id = v_rest order by l.created_at desc, l.id desc limit 50) q), '[]'::jsonb));
end $$;

-- "Regular guest" hint on the bill screen: matches the last 10 digits (so "+91 98765 43210" finds "98765 43210"). Needs only the right to take orders and
-- returns no spend figure and no phone. The guest with the most visits wins when old data holds the same number twice.
create or replace function public.find_customer(p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); v_d text; c record;
begin
  perform app.require_permission('order.create');
  v_d := right(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), 10);
  if length(v_d) < 7 then return null; end if;
  select c0.id, c0.name,
         (select count(*) from public.orders o where o.customer_id = c0.id and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null) as visits,
         (select max(o.business_date) from public.orders o where o.customer_id = c0.id and o.payment_status in ('paid', 'partially_refunded') and o.status <> 'voided' and o.merged_into is null) as last_on
    into c
    from public.customers c0
   where c0.restaurant_id = v_rest and c0.deleted_at is null and c0.phone is not null
     and right(regexp_replace(c0.phone, '[^0-9]', '', 'g'), 10) = v_d
   order by 3 desc, c0.created_at, c0.id limit 1;
  if not found then return null; end if;
  return jsonb_build_object('id', c.id, 'name', c.name, 'visits', c.visits, 'last_visit_on', c.last_on,
                            'points', case when app.feature_on(v_rest, 'loyalty') then app.points_balance(c.id) else 0 end);
end $$;

create or replace function public.update_customer(p_customer uuid, p_name text, p_email text, p_notes text, p_birthday date, p_consent boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); c public.customers%rowtype; v_name text := nullif(left(trim(coalesce(p_name, '')), 80), '');
        v_email text := nullif(left(trim(coalesce(p_email, '')), 120), ''); v_notes text := nullif(left(trim(coalesce(p_notes, '')), 500), '');
        v_consent boolean := coalesce(p_consent, false);
begin
  perform app.require_permission('customer.manage');
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest and deleted_at is null for update;
  if not found then raise exception 'Customer not found.'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right.'; end if;
  if p_birthday is not null and (p_birthday > app.local_today(v_rest) or p_birthday < date '1900-01-01') then raise exception 'That birthday does not look right.'; end if;
  update public.customers set name = coalesce(v_name, 'Guest'), email = v_email, notes = v_notes, date_of_birth = p_birthday,
         marketing_consent = v_consent,
         consent_given_at = case when v_consent and not c.marketing_consent then now() when v_consent then c.consent_given_at else null end
   where id = c.id;
  perform app.audit('customer.updated', 'customers', c.id,
    jsonb_build_object('name', coalesce(v_name, 'Guest'), 'email', v_email, 'notes', v_notes, 'date_of_birth', p_birthday, 'marketing_consent', v_consent),
    jsonb_build_object('name', c.name, 'email', c.email, 'notes', c.notes, 'date_of_birth', c.date_of_birth, 'marketing_consent', c.marketing_consent));
end $$;

-- Right to erase (DPDP): the guest's personal data is scrubbed, the bills and the sales stay. Needs customer.manage AND an owner-level approval
-- (settings.manage, so a manager can approve with the owner's PIN). Refused while the guest owes or is owed on a credit account.
create or replace function public.forget_customer(p_customer uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rest uuid := app.current_restaurant_id(); c public.customers%rowtype; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 200), ''); v_bal numeric; v_user uuid;
begin
  v_user := app.require_permission('customer.manage');
  if not app.allowed('settings.manage') then raise exception 'The owner must approve deleting a guest (settings.manage).'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Write a short reason.'; end if;
  select * into c from public.customers where id = p_customer and restaurant_id = v_rest for update;
  if not found then raise exception 'Customer not found.'; end if;
  if c.deleted_at is not null and c.name = 'Deleted guest' then raise exception 'This guest was already deleted.'; end if;
  if app.account_balance(c.id) <> 0 then raise exception 'This guest has an open credit account balance. Settle it before deleting the guest.'; end if;
  perform pg_advisory_xact_lock(hashtext('points:' || c.id::text));
  v_bal := app.points_balance(c.id);
  if v_bal <> 0 then
    insert into public.loyalty_ledger (restaurant_id, customer_id, points, kind, note, created_by)
    values (v_rest, c.id, -v_bal, 'adjust', 'Guest data deleted', v_user);
  end if;
  -- the name / phone / address printed on their bills (closed days included: this is an erasure, not a bill change)
  perform set_config('app.day_ok', 'on', true);
  update public.orders set guest_name = null, guest_phone = null, delivery_address = null where restaurant_id = v_rest and customer_id = c.id;
  perform set_config('app.day_ok', 'off', true);
  update public.customers set name = 'Deleted guest', phone = null, email = null, notes = null, date_of_birth = null, tax_registration_no = null,
         account_company = null, marketing_consent = false, consent_given_at = null, deleted_at = coalesce(deleted_at, now())
   where id = c.id;
  perform app.audit('customer.forgotten', 'customers', c.id, jsonb_build_object('customer_id', c.id, 'reason', v_reason, 'points_cleared', v_bal), null);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function public.customer_list(text, text, text, int, int), public.customer_detail(uuid), public.find_customer(text),
  public.update_customer(uuid, text, text, text, date, boolean), public.forget_customer(uuid, text),
  public.redeem_points_discount(uuid, numeric, uuid), public.remove_points_discount(uuid),
  public.save_loyalty_settings(numeric, numeric, int, text, numeric) from public, anon;
grant execute on function public.customer_list(text, text, text, int, int), public.customer_detail(uuid), public.find_customer(text),
  public.update_customer(uuid, text, text, text, date, boolean), public.forget_customer(uuid, text),
  public.redeem_points_discount(uuid, numeric, uuid), public.remove_points_discount(uuid),
  public.save_loyalty_settings(numeric, numeric, int, text, numeric) to authenticated;
