-- t140-pre.sql: runs on a database with migrations 001..139 ONLY (before 140). Builds the fixtures shared with t140.sql and records
-- "before" results (report_summary on three days, and an ordinary offline bill) so t140.sql can prove 140 leaves them unchanged.
-- Run as a superuser. Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
create table t.before (k text primary key, v jsonb);
grant usage on schema t to public; grant all on all tables in schema t to public; grant usage on all sequences in schema t to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t140:' || p)::uuid $$;
create function t.as_(p text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', t.id('auth:' || p)::text, false); perform set_config('role', 'authenticated', false); end $$;
create function t.eq(p_label text, p_actual jsonb, p_expected jsonb) returns void language plpgsql as $$
begin insert into t.res(ok, label, detail) values (p_actual is not distinct from p_expected, p_label,
  case when p_actual is not distinct from p_expected then null else 'expected ' || p_expected::text || E'\n   got      ' || coalesce(p_actual::text, 'NULL') end); end $$;
create function t.norm(j jsonb) returns jsonb language sql immutable as $$
  select case jsonb_typeof(j)
    when 'number' then to_jsonb(trim_scale((j #>> '{}')::numeric))
    when 'array' then coalesce((select jsonb_agg(t.norm(e) order by ord) from jsonb_array_elements(j) with ordinality as x(e, ord)), '[]'::jsonb)
    when 'object' then coalesce((select jsonb_object_agg(k, t.norm(v)) from jsonb_each(j) as x(k, v)), '{}'::jsonb)
    else j end $$;
create function t.same(p_label text, p_actual jsonb, p_expected text) returns void language sql as $$
  select t.eq(p_label, t.norm(p_actual), t.norm(p_expected::jsonb)) $$;
create function t.q(p_label text, p_actual anyelement, p_expected text) returns void language sql as $$
  select t.eq(p_label, t.norm(to_jsonb(p_actual)), t.norm(p_expected::jsonb)) $$;
create function t.err(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
declare m text;
begin
  begin execute p_sql; m := 'NO ERROR';
  exception when others then m := sqlerrm; end;
  insert into t.res(ok, label, detail) values (position(p_expect in m) > 0, p_label, case when position(p_expect in m) > 0 then null else 'expected error containing [' || p_expect || '] got [' || m || ']' end);
end $$;
-- an offline bill the way the till sends it: number = <bill prefix>-X<device>-<seq>
create function t.bill(p_dev int, p_seq int, p_items jsonb, p_ref text) returns jsonb language sql stable as $$
  select jsonb_build_object('client_id', t.id(p_ref), 'device_key', t.id('dev' || p_dev)::text, 'seq', p_seq,
    'number', 'T-X' || p_dev || '-' || lpad(p_seq::text, 4, '0'), 'order_type', 'takeaway', 'method_id', t.id('pmCash'), 'items', p_items) $$;
create function t.item(p_prod text, p_qty numeric, p_price numeric) returns jsonb language sql immutable as $$
  select jsonb_build_object('product_id', t.id(p_prod), 'qty', p_qty, 'price', p_price, 'options', '[]'::jsonb) $$;
create function t.mk_order(k text, p_date date, p_type text, p_status text, p_pay text, p_covers int, p_grand numeric, p_merged text default null) returns void language plpgsql as $$
begin
  insert into public.orders (id, restaurant_id, branch_id, bill_number, order_type, cashier_id, currency_code, client_created_at, created_at, business_date,
                             status, payment_status, covers, subtotal, grand_total, merged_into, voided_by, void_reason, voided_at)
  values (t.id(k), t.id('rest1'), t.id('outA'), upper(k), p_type, t.id('carl'), 'INR', p_date::timestamptz + interval '8 hours', p_date::timestamptz + interval '8 hours', p_date,
          p_status, p_pay, p_covers, p_grand, p_grand, case when p_merged is null then null else t.id(p_merged) end,
          case when p_status = 'voided' then t.id('owner') end, case when p_status = 'voided' then 'test void' end, case when p_status = 'voided' then p_date::timestamptz + interval '9 hours' end);
end $$;

-- ---------------------------------------------------------------- fixtures
do $$
declare r1 uuid := t.id('rest1'); a uuid := t.id('outA'); x text;
begin
  insert into public.restaurants (id, legal_name, trading_name, country_code, currency_code, timezone, edition)
    values (r1, 'Test One Pvt Ltd', 'Test One', 'IN', 'INR', 'Asia/Kolkata', 'professional');
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone) values (a, r1, 'Outlet A', 'A', 'IN', 'Asia/Kolkata');
  insert into public.tax_groups (id, restaurant_id, name) values (t.id('tax1'), r1, 'GST');
  insert into public.categories (id, restaurant_id, name) values (t.id('catFood'), r1, 'Food'), (t.id('catDrinks'), r1, 'Drinks');
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values
    (t.id('burger'), r1, t.id('catFood'), t.id('tax1'), 'Burger', 100), (t.id('tea'), r1, t.id('catDrinks'), t.id('tax1'), 'Tea', 20),
    (t.id('free'), r1, t.id('catFood'), t.id('tax1'), 'Water', 0), (t.id('lux'), r1, t.id('catFood'), t.id('tax1'), 'Caviar', 9999999);
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price, is_open_price) values
    (t.id('special'), r1, t.id('catFood'), t.id('tax1'), 'Chef Special', 10, true);
  insert into public.roles (id, restaurant_id, name, is_system) values
    (t.id('roleOwner'), r1, 'Owner', true), (t.id('roleMgr'), r1, 'Manager', false), (t.id('roleCashier'), r1, 'Cashier', false);
  insert into public.role_permissions (role_id, permission_key) values
    (t.id('roleOwner'), 'order.create'), (t.id('roleOwner'), 'order.open_price'), (t.id('roleOwner'), 'menu.price_change'), (t.id('roleOwner'), 'report.view_sales'), (t.id('roleOwner'), 'report.view_financial'),
    (t.id('roleMgr'), 'order.create'), (t.id('roleMgr'), 'order.open_price'), (t.id('roleMgr'), 'menu.price_change'),
    (t.id('roleCashier'), 'order.create');
  foreach x in array array['owner','mgr','carl'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t140.test');
  end loop;
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values
    (t.id('owner'), r1, t.id('auth:owner'), 'E1', 'Olivia Owner', t.id('roleOwner'),   'owner@t140.test'),
    (t.id('mgr'),   r1, t.id('auth:mgr'),   'E2', 'Maya Manager', t.id('roleMgr'),     'mgr@t140.test'),
    (t.id('carl'),  r1, t.id('auth:carl'),  'E3', 'Carl Cashier', t.id('roleCashier'), 'carl@t140.test');
  insert into public.payment_methods (id, restaurant_id, name, kind) values (t.id('pmCash'), r1, 'Cash', 'cash'), (t.id('pmUpi'), r1, 'UPI', 'upi');
  insert into public.bill_series (restaurant_id, branch_id, prefix, next_seq, is_current) values (r1, a, 'T', 1, true);
  insert into public.offline_series (restaurant_id, branch_id, device_key, prefix) values
    (r1, a, t.id('dev1')::text, 'X1'), (r1, a, t.id('dev2')::text, 'X2'), (r1, a, t.id('dev3')::text, 'X3');
end $$;

-- summary fixtures: days 2026-10-20 (D, busy), 2026-10-21 (E, a day with one tip and no bills)
set session_replication_role = replica;
insert into public.business_days (restaurant_id, branch_id, business_date, status) values (t.id('rest1'), t.id('outA'), '2026-10-20', 'closed'), (t.id('rest1'), t.id('outA'), '2026-10-21', 'closed');
select t.mk_order('s1', '2026-10-20', 'dine_in',  'completed', 'paid',   4, 400);
select t.mk_order('s2', '2026-10-20', 'dine_in',  'completed', 'paid',   2, 300);
select t.mk_order('s3', '2026-10-20', 'dine_in',  'completed', 'paid',   null, 200);
select t.mk_order('s4', '2026-10-20', 'dine_in',  'voided',    'paid',   3, 150);
select t.mk_order('s5', '2026-10-20', 'takeaway', 'completed', 'paid',   null, 100);
select t.mk_order('s6', '2026-10-20', 'dine_in',  'completed', 'paid',   5, 50, 's1');
select t.mk_order('s7', '2026-10-20', 'dine_in',  'completed', 'unpaid', 3, 90);
insert into public.order_items (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, line_subtotal, line_total, net_amount) values
  (t.id('i1'), t.id('rest1'), t.id('s1'), t.id('burger'), 'Burger', 100, 4, 400, 400, 400), (t.id('i2'), t.id('rest1'), t.id('s2'), t.id('tea'), 'Tea', 20, 15, 300, 300, 300);
insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, received_by, client_created_at, status) values
  (t.id('p1'), t.id('rest1'), t.id('s1'), t.id('pmCash'), 400, 'INR', t.id('owner'), '2026-10-20 08:30+00', 'captured'),
  (t.id('p2'), t.id('rest1'), t.id('s2'), t.id('pmUpi'),  300, 'INR', t.id('owner'), '2026-10-20 08:30+00', 'captured'),
  (t.id('p3'), t.id('rest1'), t.id('s3'), t.id('pmCash'), 200, 'INR', t.id('owner'), '2026-10-20 08:30+00', 'captured'),
  (t.id('p5'), t.id('rest1'), t.id('s5'), t.id('pmCash'), 100, 'INR', t.id('owner'), '2026-10-20 08:30+00', 'captured');
-- tips: two that count, one on the voided bill (left out), one on another day (left out)
insert into public.order_tips (restaurant_id, branch_id, order_id, amount, business_date) values
  (t.id('rest1'), t.id('outA'), t.id('s1'), 30, '2026-10-20'), (t.id('rest1'), t.id('outA'), t.id('s2'), 20, '2026-10-20'),
  (t.id('rest1'), t.id('outA'), t.id('s4'), 99, '2026-10-20'), (t.id('rest1'), t.id('outA'), t.id('s5'), 10, '2026-10-21');
set session_replication_role = default;

-- ---------------------------------------------------------------- "before" results (migrations up to 139)
insert into t.before values
  ('sum_D', app.report_summary(t.id('outA'), '2026-10-20')),
  ('sum_E', app.report_summary(t.id('outA'), '2026-10-21')),
  ('sum_none', app.report_summary(t.id('outA'), '2026-10-25')),
  ('sum_nobranch', coalesce(app.report_summary(t.id('nowhere'), '2026-10-20'), 'null'::jsonb));

-- an ordinary offline bill on device 2 (no open-priced item): Burger at the right price, Tea at a price the menu never had
select t.as_('carl');
select public.sync_offline_bill(t.bill(2, 1, jsonb_build_array(t.item('burger', 2, 100), t.item('tea', 1, 5)), 'pre1')) as r \gset
reset role;
insert into t.before select 'sync_normal', jsonb_build_object('res', (:'r'::jsonb) - array['order_id','bill_number'],
  'flags', (select o.offline_flags from public.orders o where o.client_ref = t.id('pre1')),
  'total', (select o.grand_total from public.orders o where o.client_ref = t.id('pre1')),
  'prices', (select jsonb_agg(oi.unit_price order by oi.product_name) from public.order_items oi join public.orders o on o.id = oi.order_id where o.client_ref = t.id('pre1')),
  'open_flags', (select jsonb_agg(oi.open_price) from public.order_items oi join public.orders o on o.id = oi.order_id where o.client_ref = t.id('pre1')),
  'audits', (select jsonb_agg(a.action order by a.action) from public.audit_logs a join public.orders o on o.id = a.entity_id where o.client_ref = t.id('pre1')));
