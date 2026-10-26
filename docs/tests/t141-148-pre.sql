-- t141-148-pre.sql: runs on a database with migrations 001..140 ONLY (before 141). Builds the fixtures shared with t141-148.sql (the real
-- create_restaurant_with_owner, so the real roles and grants), records "before" golden bills (quote_order / create_order / add_order_items / pay_order,
-- ordinary items), an ordinary guest-less offline bill, a copy of the OLD app.calc_bill (t.calc_old) for the random comparison, and a customer
-- with a paid bill (so the privacy and stats tests have history). Run as a superuser. Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
create table t.gold (phase text, label text, result jsonb, primary key (phase, label));
create table t.ctx (k text primary key, v text);
create table t.before (k text primary key, v jsonb);
grant usage on schema t to public; grant all on all tables in schema t to public; grant usage on all sequences in schema t to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t141:' || p)::uuid $$;
create function t.ctx(p text) returns uuid language sql stable as $$ select v::uuid from t.ctx where k = p $$;
create function t.as_(p text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', t.id('auth:' || p)::text, false); perform set_config('role', 'authenticated', false); end $$;
-- as_su = be that person but stay superuser (calls the definer RPCs exactly as the app would, without the role switch)
create function t.as_su(p text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', t.id('auth:' || p)::text, false); perform set_config('role', 'postgres', false); end $$;
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
create function t.is_(p_label text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into t.res(ok, label, detail) values (coalesce(p_ok, false), p_label, case when coalesce(p_ok, false) then null else p_detail end) $$;
create function t.err(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
declare m text;
begin
  begin execute p_sql; m := 'NO ERROR';
  exception when others then m := sqlerrm; end;
  insert into t.res(ok, label, detail) values (position(p_expect in m) > 0, p_label, case when position(p_expect in m) > 0 then null else 'expected error containing [' || p_expect || '] got [' || m || ']' end);
end $$;

-- ---------------------------------------------------------------- fixtures
do $$
declare r uuid; b uuid; cat uuid; gst5 uuid; gst18 uuid; ginc uuid; rate uuid; x text; role_mgr uuid; role_cash uuid; role_own uuid; role_wait uuid; role_chef uuid; role_cust uuid;
begin
  foreach x in array array['owner','mgr','cash','wait','chef','cust','other'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t141.test');
  end loop;
  perform set_config('request.jwt.claim.sub', t.id('auth:owner')::text, false);
  r := public.create_restaurant_with_owner('T141 Foods Pvt Ltd', 'T141 Kitchen', 'IN', 'Owner T', 'Main', 'MN');
  update public.restaurants set edition = 'professional' where id = r;
  select id into b from public.branches where restaurant_id = r;
  select id into role_own  from public.roles where restaurant_id = r and name = 'Owner';
  select id into role_mgr  from public.roles where restaurant_id = r and name = 'Manager';
  select id into role_cash from public.roles where restaurant_id = r and name = 'Cashier';
  select id into role_wait from public.roles where restaurant_id = r and name = 'Steward';
  select id into role_chef from public.roles where restaurant_id = r and name = 'Chef';
  -- a custom role (not a system role) that can manage customers and stock: must receive customer.view / stock.view by the grant copy
  insert into public.roles (restaurant_id, name, is_system) values (r, 'Front desk', false) returning id into role_cust;
  insert into public.role_permissions (role_id, permission_key) values (role_cust, 'customer.manage'), (role_cust, 'order.create');
  insert into public.users (restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values
    (r, t.id('auth:mgr'),  'EMP2', 'Manny Manager', role_mgr,  'mgr@t141.test'),
    (r, t.id('auth:cash'), 'EMP3', 'Cathy Cashier', role_cash, 'cash@t141.test'),
    (r, t.id('auth:wait'), 'EMP4', 'Wendy Waiter',  role_wait, 'wait@t141.test'),
    (r, t.id('auth:chef'), 'EMP5', 'Charlie Chef',  role_chef, 'chef@t141.test'),
    (r, t.id('auth:cust'), 'EMP6', 'Fiona Frontdesk', role_cust, 'cust@t141.test');
  insert into public.user_branches (user_id, branch_id, restaurant_id) select u.id, b, r from public.users u where u.restaurant_id = r and u.auth_user_id <> t.id('auth:owner');
  update public.users set all_outlets = true where auth_user_id = t.id('auth:owner');
  insert into t.ctx values ('r', r::text), ('b', b::text), ('roleOwner', role_own::text), ('roleMgr', role_mgr::text), ('roleCash', role_cash::text),
    ('roleWait', role_wait::text), ('roleChef', role_chef::text), ('roleCust', role_cust::text);
  select id into gst5 from public.tax_groups where restaurant_id = r and name ~ '5\s*%' and name !~ '12|18' limit 1;
  select id into gst18 from public.tax_groups where restaurant_id = r and name ~ '18\s*%' limit 1;
  if gst5 is null or gst18 is null then raise exception 'fixture: expected GST 5 and 18 groups'; end if;
  insert into public.tax_groups (restaurant_id, name, is_price_inclusive) values (r, 'T Inclusive 7', true) returning id into ginc;
  insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from) values (r, ginc, 7, date '2020-01-01') returning id into rate;
  insert into public.tax_rate_components (restaurant_id, tax_rate_id, name, rate, applies_when, display_order) values (r, rate, 'VAT', 7, 'always', 1);
  update public.tax_rates set valid_from = date '2020-01-01' where restaurant_id = r and valid_from > date '2020-01-01';
  insert into t.ctx values ('gst5', gst5::text), ('gst18', gst18::text), ('ginc', ginc::text);
  insert into public.categories (restaurant_id, name, display_order) values (r, 'Mains', 1) returning id into cat;
  insert into t.ctx values ('cat', cat::text);
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values
    (t.id('dosa'), r, cat, gst5, 'Masala Dosa', 120), (t.id('biryani'), r, cat, gst5, 'Chicken Biryani', 249.5),
    (t.id('cola'), r, cat, gst18, 'Cola', 60), (t.id('thali'), r, cat, gst5, 'Veg Thali', 333.33),
    (t.id('inc'), r, cat, ginc, 'Inclusive Snack', 107);
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values (t.id('special'), r, cat, gst5, 'Chef Special', 0.01);
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats) values
    (t.id('T1'), r, b, 'T1', 4), (t.id('T2'), r, b, 'T2', 4), (t.id('T3'), r, b, 'T3', 4), (t.id('T4'), r, b, 'T4', 4), (t.id('T5'), r, b, 'T5', 4), (t.id('T6'), r, b, 'T6', 4);
  insert into t.ctx select 'pmCash', id::text from public.payment_methods where restaurant_id = r and kind = 'cash' and is_active order by display_order limit 1;
  insert into t.ctx select 'pmUpi', id::text from public.payment_methods where restaurant_id = r and kind = 'upi' and is_active order by display_order limit 1;
  update public.branch_settings set service_charge_percent = 5, service_charge_taxable = false where branch_id = b;
  -- the loyalty add-on (like a restaurant that bought it before 141)
  insert into public.restaurant_modules (restaurant_id, module_key) values (r, 'loyalty');
  -- a second outlet (orders are inserted directly for the scope tests) and a second restaurant for isolation tests
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone) values (t.id('outB'), r, 'Outlet B', 'B', 'IN', 'Asia/Kolkata');
  insert into public.devices (restaurant_id, branch_id, name, device_type, bill_prefix) values (r, t.id('outB'), 'Counter B', 'tablet', 'CB');
  update public.users set current_branch_id = b where auth_user_id = t.id('auth:owner');   -- the owner works in Main unless a test says otherwise
  perform set_config('request.jwt.claim.sub', t.id('auth:other')::text, false);
  r := public.create_restaurant_with_owner('T141 Other Pvt Ltd', 'T141 Other', 'IN', 'Other Owner', 'Main', 'MN');
  insert into t.ctx values ('r2', r::text);
end $$;

-- loyalty rules as an existing restaurant had them: the 3-argument function, no mode (mode stays 'tender' after 145)
select t.as_su('owner');
select public.save_loyalty_settings(10, 1, 10);
select set_config('role', 'postgres', false);

-- ---------------------------------------------------------------- the OLD app.calc_bill, kept for the random comparison
do $$ declare d text;
begin
  d := pg_get_functiondef('app.calc_bill(jsonb)'::regprocedure);
  d := replace(d, 'FUNCTION app.calc_bill(', 'FUNCTION t.calc_old(');
  execute d;
end $$;

-- ---------------------------------------------------------------- golden scenarios (ordinary items only)
create function t.snap(p_order uuid) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'order', (select jsonb_build_object('subtotal', o.subtotal, 'discount', o.discount_total, 'tax', o.tax_total, 'sc', o.service_charge,
                'rounding', o.rounding_adjustment, 'grand', o.grand_total, 'paid', o.paid_total, 'pstatus', o.payment_status,
                'tax_included', o.tax_included, 'exempt', o.exempt_sales, 'covered', app.order_covered(o.id)) from public.orders o where o.id = p_order),
    'items', (select jsonb_agg(jsonb_build_object('name', i.product_name, 'unit', i.unit_price, 'qty', i.quantity, 'mod', i.modifier_total,
                'sub', i.line_subtotal, 'disc', i.line_discount, 'tax', i.line_tax, 'total', i.line_total, 'incl', i.is_price_inclusive,
                'net', i.net_amount, 'sc', i.service_charge, 'taxinc', i.tax_included, 'comps', i.tax_comps) order by i.product_name, i.unit_price, i.quantity)
              from public.order_items i where i.order_id = p_order),
    'discounts', (select coalesce(jsonb_agg(jsonb_build_object('type', d.discount_type, 'value', d.value, 'amount', d.amount) order by d.discount_type), '[]'::jsonb) from public.order_discounts d where d.order_id = p_order),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('amount', py.amount, 'tendered', py.tendered_amount, 'change', py.change_amount, 'rounding', py.rounding_adjustment) order by py.amount, py.created_at), '[]'::jsonb)
              from public.payments py where py.order_id = p_order)) $$;
create function t.items(p jsonb) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('product_id', t.id(e.key), 'qty', e.value::numeric)) from jsonb_each_text(p) e $$;
create function t.run_golden(p_phase text, p_t1 text, p_t2 text) returns void language plpgsql as $$
declare v jsonb; o uuid; o2 uuid; pm uuid := t.ctx('pmCash'); n int := 0;
  scen jsonb := '[
    {"l":"q1","i":{"dosa":2}},
    {"l":"q2","i":{"dosa":1,"cola":3}},
    {"l":"q3","i":{"dosa":2,"biryani":1,"thali":1},"d":25},
    {"l":"q4","i":{"dosa":2,"cola":1},"sc":true},
    {"l":"q5","i":{"inc":3,"dosa":1}},
    {"l":"q6","i":{"dosa":3,"biryani":2,"cola":5,"thali":1,"inc":2,"special":7},"d":10,"sc":true}]';
  s jsonb;
begin
  perform t.as_su('owner');
  for s in select * from jsonb_array_elements(scen) loop
    v := public.quote_order(t.items(s->'i'), coalesce((s->>'d')::numeric, 0), (s->>'sc')::boolean, null);
    insert into t.gold values (p_phase, s->>'l', v);
  end loop;
  perform t.as_su('cash');
  v := public.create_order(t.items('{"dosa":2,"cola":1}'), 'dine_in', t.id(p_t1), null, null, null, 0, null, true, null, null, null, null);
  o := (v->>'order_id')::uuid;
  insert into t.gold values (p_phase, 'c1', t.snap(o));
  v := public.add_order_items(o, t.items('{"biryani":1,"inc":2}'));
  insert into t.gold values (p_phase, 'c1b', t.snap(o));
  v := public.pay_order(o, pm, null, 100);
  insert into t.gold values (p_phase, 'p1', v - 'order_id' - 'bill_number');
  v := public.pay_order(o, pm, 2000, null);
  insert into t.gold values (p_phase, 'p2', v - 'order_id' - 'bill_number');
  insert into t.gold values (p_phase, 'c1c', t.snap(o));
  v := public.create_order(t.items('{"thali":2,"cola":2}'), 'takeaway', null, null, pm, 2000, 0, null, false, null, null, null, null);
  insert into t.gold values (p_phase, 'c2', t.snap((v->>'order_id')::uuid) || jsonb_build_object('ret', v - 'order_id' - 'bill_number'));
  perform t.as_su('owner');
  v := public.create_order(t.items('{"dosa":4,"biryani":1}'), 'dine_in', t.id(p_t2), null, null, null, 30, 'regular', true, null, null, null, null);
  o2 := (v->>'order_id')::uuid;
  insert into t.gold values (p_phase, 'c3', t.snap(o2));
  -- complimentary (make_complimentary is rewritten by 141)
  v := public.create_order(t.items('{"dosa":1,"cola":1}'), 'takeaway', null, null, null, null, 0, null, true, null, null, null, null);
  perform public.make_complimentary((v->>'order_id')::uuid, 'complimentary', 'owner guest');
  insert into t.gold values (p_phase, 'comp', t.snap((v->>'order_id')::uuid));
  perform set_config('role', 'postgres', false);
end $$;
select t.run_golden('before', 'T1', 'T2');

-- ---------------------------------------------------------------- a customer with history (legacy: made by a bill phone before 145)
select t.as_su('cash');
select public.create_order(t.items('{"dosa":2,"cola":1}'), 'takeaway', null, null, t.ctx('pmCash'), 2000, 0, null, false, null, null, null,
  jsonb_build_object('guest_name', 'Asha Legacy', 'guest_phone', '98765 43210')) as r \gset
select set_config('role', 'postgres', false);
insert into t.ctx values ('legacyBill', (:'r'::jsonb ->> 'order_id'));
insert into t.before values ('legacy_points', jsonb_build_object('pts', (select coalesce(sum(points), 0) from public.loyalty_ledger l join public.customers c on c.id = l.customer_id where c.phone like '%9876543210')));

-- ---------------------------------------------------------------- an ordinary guest-less offline bill (before 147)
insert into public.offline_series (restaurant_id, branch_id, device_key, prefix) values
  (t.ctx('r'), t.ctx('b'), t.id('dev1')::text, 'X1'), (t.ctx('r'), t.ctx('b'), t.id('dev2')::text, 'X2'), (t.ctx('r'), t.ctx('b'), t.id('dev3')::text, 'X3');
create function t.obill(p_dev int, p_seq int, p_items jsonb, p_ref text, p_extra jsonb default '{}'::jsonb) returns jsonb language sql stable as $$
  select jsonb_build_object('client_id', t.id(p_ref), 'device_key', t.id('dev' || p_dev)::text, 'seq', p_seq,
    'number', (select prefix from public.bill_series where branch_id = t.ctx('b') and is_current limit 1) || '-X' || p_dev || '-' || lpad(p_seq::text, 4, '0'),
    'order_type', 'takeaway', 'method_id', t.id('pmCashDummy'), 'items', p_items) || p_extra $$;
create function t.oitem(p_prod text, p_qty numeric, p_price numeric) returns jsonb language sql immutable as $$
  select jsonb_build_object('product_id', t.id(p_prod), 'qty', p_qty, 'price', p_price, 'options', '[]'::jsonb) $$;
select t.as_su('cash');
select public.sync_offline_bill(t.obill(2, 1, jsonb_build_array(t.oitem('dosa', 2, 120), t.oitem('cola', 1, 5)), 'pre1') || jsonb_build_object('method_id', t.ctx('pmCash'))) as r \gset
select set_config('role', 'postgres', false);
insert into t.before select 'sync_normal', jsonb_build_object('res', (:'r'::jsonb) - array['order_id','bill_number'],
  'flags', (select o.offline_flags from public.orders o where o.client_ref = t.id('pre1')),
  'total', (select o.grand_total from public.orders o where o.client_ref = t.id('pre1')),
  'prices', (select jsonb_agg(oi.unit_price order by oi.product_name) from public.order_items oi join public.orders o on o.id = oi.order_id where o.client_ref = t.id('pre1')),
  'cust', (select o.customer_id is null from public.orders o where o.client_ref = t.id('pre1')));
\o
select 'pre done: golden ' || count(*) || ', customers ' || (select count(*) from public.customers) from t.gold;
