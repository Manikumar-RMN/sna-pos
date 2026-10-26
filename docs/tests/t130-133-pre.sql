-- t130-133-pre.sql: runs on a database with migrations 001..129 ONLY. Builds fixtures and records "before" golden bill results
-- (quote_order, create_order, add_order_items, pay_order) for ordinary items. t130-133.sql replays the same scenarios after
-- migrations 130, 131 and 133 and requires byte-identical results. Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
create table t.gold (phase text, label text, result jsonb, primary key (phase, label));
create table t.ctx (k text primary key, v text);
grant usage on schema t to public; grant all on all tables in schema t to public; grant usage on all sequences in schema t to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t130:' || p)::uuid $$;
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
create function t.is_(p_label text, p_ok boolean, p_detail text default null) returns void language sql as $$
  insert into t.res(ok, label, detail) values (coalesce(p_ok, false), p_label, case when coalesce(p_ok, false) then null else p_detail end) $$;
create function t.err(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
declare m text;
begin
  begin execute p_sql; m := 'NO ERROR';
  exception when others then m := sqlerrm; end;
  insert into t.res(ok, label, detail) values (position(p_expect in m) > 0, p_label, case when position(p_expect in m) > 0 then null else 'expected error containing [' || p_expect || '] got [' || m || ']' end);
end $$;

-- ---------------------------------------------------------------- fixtures (real create_restaurant_with_owner, real roles)
do $$
declare r uuid; b uuid; cat uuid; gst5 uuid; gst18 uuid; ginc uuid; rate uuid; x text; role_mgr uuid; role_cash uuid; role_own uuid; u uuid; p uuid;
begin
  foreach x in array array['owner','mgr','cash','other'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t130.test');
  end loop;
  perform set_config('request.jwt.claim.sub', t.id('auth:owner')::text, false);
  r := public.create_restaurant_with_owner('T130 Foods Pvt Ltd', 'T130 Kitchen', 'IN', 'Owner T', 'Main', 'MN');
  select id into b from public.branches where restaurant_id = r;
  select id into role_own from public.roles where restaurant_id = r and name = 'Owner';
  select id into role_mgr from public.roles where restaurant_id = r and name = 'Manager';
  select id into role_cash from public.roles where restaurant_id = r and name = 'Cashier';
  insert into public.users (restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values
    (r, t.id('auth:mgr'), 'EMP2', 'Manny Manager', role_mgr, 'mgr@t130.test'),
    (r, t.id('auth:cash'), 'EMP3', 'Cathy Cashier', role_cash, 'cash@t130.test');
  insert into public.user_branches (user_id, branch_id, restaurant_id) select u.id, b, r from public.users u where u.restaurant_id = r and u.auth_user_id in (t.id('auth:mgr'), t.id('auth:cash'));
  insert into t.ctx values ('r', r::text), ('b', b::text), ('roleOwner', role_own::text), ('roleMgr', role_mgr::text), ('roleCash', role_cash::text);
  select id into gst5 from public.tax_groups where restaurant_id = r and name ~ '5\s*%' and name !~ '12|18' limit 1;
  select id into gst18 from public.tax_groups where restaurant_id = r and name ~ '18\s*%' limit 1;
  if gst5 is null or gst18 is null then raise exception 'fixture: expected GST 5 and 18 groups'; end if;
  -- a tax-inclusive group of our own (7%)
  insert into public.tax_groups (restaurant_id, name, is_price_inclusive) values (r, 'T Inclusive 7', true) returning id into ginc;
  insert into public.tax_rates (restaurant_id, tax_group_id, total_rate, valid_from) values (r, ginc, 7, date '2020-01-01') returning id into rate;
  insert into public.tax_rate_components (restaurant_id, tax_rate_id, name, rate, applies_when, display_order) values (r, rate, 'VAT', 7, 'always', 1);
  -- every seeded rate starts long ago, so the run does not depend on the time of day it is executed
  update public.tax_rates set valid_from = date '2020-01-01' where restaurant_id = r and valid_from > date '2020-01-01';
  insert into t.ctx values ('gst5', gst5::text), ('gst18', gst18::text), ('ginc', ginc::text);
  insert into public.categories (restaurant_id, name, display_order) values (r, 'Mains', 1) returning id into cat;
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values
    (t.id('dosa'), r, cat, gst5, 'Masala Dosa', 120), (t.id('biryani'), r, cat, gst5, 'Chicken Biryani', 249.5),
    (t.id('cola'), r, cat, gst18, 'Cola', 60), (t.id('thali'), r, cat, gst5, 'Veg Thali', 333.33),
    (t.id('inc'), r, cat, ginc, 'Inclusive Snack', 107);
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values (t.id('special'), r, cat, gst5, 'Chef Special', 0.01);
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats) values (t.id('T1'), r, b, 'T1', 4), (t.id('T2'), r, b, 'T2', 4);
  insert into t.ctx select 'pmCash', id::text from public.payment_methods where restaurant_id = r and kind = 'cash' and is_active order by display_order limit 1;
  insert into t.ctx select 'pmUpi', id::text from public.payment_methods where restaurant_id = r and kind = 'upi' and is_active order by display_order limit 1;
  -- a service charge so the quote has one to work out
  update public.branch_settings set service_charge_percent = 5, service_charge_taxable = false where branch_id = b;
  -- a second restaurant (owner 'other') for isolation tests
  perform set_config('request.jwt.claim.sub', t.id('auth:other')::text, false);
  r := public.create_restaurant_with_owner('T130 Other Pvt Ltd', 'T130 Other', 'IN', 'Other Owner', 'Main', 'MN');
  insert into t.ctx values ('r2', r::text);
  select id into gst5 from public.tax_groups where restaurant_id = r and name ~ '5\s*%' and name !~ '12|18' limit 1;
  insert into t.ctx values ('r2gst5', gst5::text);
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
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('amount', py.amount, 'tendered', py.tendered_amount, 'change', py.change_amount, 'rounding', py.rounding_adjustment) order by py.amount, py.created_at), '[]'::jsonb)
              from public.payments py where py.order_id = p_order)) $$;
create function t.items(p jsonb) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('product_id', t.id(e.key), 'qty', e.value::numeric)) from jsonb_each_text(p) e $$;
create function t.run_golden(p_phase text) returns void language plpgsql as $$
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
  -- real bills
  perform t.as_su('cash');
  v := public.create_order(t.items('{"dosa":2,"cola":1}'), 'dine_in', t.id('T1'), null, null, null, 0, null, true, null, null, null, null);
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
  v := public.create_order(t.items('{"dosa":4,"biryani":1}'), 'dine_in', t.id('T2'), null, null, null, 30, 'regular', true, null, null, null, null);
  o2 := (v->>'order_id')::uuid;
  insert into t.gold values (p_phase, 'c3', t.snap(o2));
  perform set_config('role', 'postgres', false);
end $$;
select t.run_golden('before');
-- put the tables back to a clean slate for the second run: close the day so t130133 starts on a fresh bill set
\o
select 'golden before recorded: ' || count(*) from t.gold where phase = 'before';
