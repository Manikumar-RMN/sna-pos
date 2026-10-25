-- t128.sql: proves the four report-pack RPCs of migration 128 on a database with migrations 001..128 applied.
-- Run as a superuser (it creates its own fixtures and impersonates users with SET ROLE authenticated + JWT claims).
-- Re-runnable: it drops and recreates schema "t" and removes the fixture restaurants it made. Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
set session_replication_role = replica;      -- fixtures are written straight into the tables (no billing triggers); the RPCs under test are read-only
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
grant usage on schema t to public; grant all on t.res to public; grant usage on sequence t.res_n_seq to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t128:' || p)::uuid $$;
-- as_ = become that person (like a signed-in browser). Back to superuser: RESET ROLE.
create function t.as_(p text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', t.id('auth:' || p)::text, false); perform set_config('role', 'authenticated', false); end $$;
create function t.eq(p_label text, p_actual jsonb, p_expected jsonb) returns void language plpgsql as $$
begin insert into t.res(ok, label, detail) values (p_actual is not distinct from p_expected, p_label,
  case when p_actual is not distinct from p_expected then null else 'expected ' || p_expected::text || E'\n   got      ' || coalesce(p_actual::text, 'NULL') end); end $$;
-- numbers compare as numbers even if jsonb prints 450 vs 450.00
create function t.norm(j jsonb) returns jsonb language sql immutable as $$
  select case jsonb_typeof(j)
    when 'number' then to_jsonb(trim_scale((j #>> '{}')::numeric))
    when 'array' then coalesce((select jsonb_agg(t.norm(e) order by ord) from jsonb_array_elements(j) with ordinality as x(e, ord)), '[]'::jsonb)
    when 'object' then coalesce((select jsonb_object_agg(k, t.norm(v)) from jsonb_each(j) as x(k, v)), '{}'::jsonb)
    else j end $$;
create function t.same(p_label text, p_actual jsonb, p_expected text) returns void language sql as $$
  select t.eq(p_label, t.norm(p_actual), t.norm(p_expected::jsonb)) $$;
create function t.err(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
declare m text;
begin
  begin execute p_sql; m := 'NO ERROR';
  exception when others then m := sqlerrm; end;
  insert into t.res(ok, label, detail) values (position(p_expect in m) > 0, p_label, case when position(p_expect in m) > 0 then null else 'expected error containing [' || p_expect || '] got [' || m || ']' end);
end $$;
-- the one-line view of a list for readable expectations
create function t.names(j jsonb, k text) returns jsonb language sql immutable as $$ select coalesce(jsonb_agg(e -> k), '[]'::jsonb) from jsonb_array_elements(j) e $$;

-- ---------------------------------------------------------------- fixtures
delete from auth.users where id in (select t.id('auth:' || x) from unnest(array['owner','carl','mgr','nina','wendy','wes','other']) x);
do $$
declare r1 uuid := t.id('rest1'); r2 uuid := t.id('rest2'); a uuid := t.id('outA'); b uuid := t.id('outB'); c uuid := t.id('outC');
  tg uuid := t.id('tax1'); tg2 uuid := t.id('tax2'); cat uuid := t.id('cat1'); cat2 uuid := t.id('cat2');
  x text;
begin
  -- clean any earlier run of this test
  delete from public.order_items where restaurant_id in (r1, r2);
  delete from public.orders where restaurant_id in (r1, r2);
  delete from public.branch_prices where restaurant_id in (r1, r2);
  delete from public.user_branches where restaurant_id in (r1, r2);
  delete from public.role_permissions where role_id in (select id from public.roles where restaurant_id in (r1, r2));
  update public.users set current_branch_id = null where restaurant_id in (r1, r2);
  delete from public.users where restaurant_id in (r1, r2);
  delete from public.roles where restaurant_id in (r1, r2);
  delete from public.products where restaurant_id in (r1, r2);
  delete from public.categories where restaurant_id in (r1, r2);
  delete from public.tax_groups where restaurant_id in (r1, r2);
  delete from public.branches where restaurant_id in (r1, r2);
  delete from public.restaurants where id in (r1, r2);

  insert into public.restaurants (id, legal_name, trading_name, country_code, currency_code, timezone, edition)
    values (r1, 'Test One Pvt Ltd', 'Test One', 'IN', 'INR', 'Asia/Kolkata', 'professional'),
           (r2, 'Test Two Pvt Ltd', 'Test Two', 'IN', 'INR', 'Asia/Kolkata', 'professional');
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone)
    values (a, r1, 'Outlet A', 'A', 'IN', 'Asia/Kolkata'), (b, r1, 'Outlet B', 'B', 'IN', 'Asia/Kolkata'), (c, r2, 'Outlet C', 'C', 'IN', 'Asia/Kolkata');
  insert into public.tax_groups (id, restaurant_id, name) values (tg, r1, 'GST'), (tg2, r2, 'GST');
  insert into public.categories (id, restaurant_id, name) values (cat, r1, 'Food'), (cat2, r2, 'Food');

  -- roles: Owner (system), Manager (sales + financial), Cashier (sales only), Nobody (no report rights)
  insert into public.roles (id, restaurant_id, name, is_system) values
    (t.id('roleOwner'), r1, 'Owner', true), (t.id('roleMgr'), r1, 'Manager', false), (t.id('roleCashier'), r1, 'Cashier', false), (t.id('roleNobody'), r1, 'Nobody', false),
    (t.id('roleOwner2'), r2, 'Owner', true);
  insert into public.role_permissions (role_id, permission_key) values
    (t.id('roleOwner'), 'report.view_sales'), (t.id('roleOwner'), 'report.view_financial'),
    (t.id('roleMgr'), 'report.view_sales'), (t.id('roleMgr'), 'report.view_financial'),
    (t.id('roleCashier'), 'report.view_sales'),
    (t.id('roleOwner2'), 'report.view_sales'), (t.id('roleOwner2'), 'report.view_financial');

  foreach x in array array['owner','carl','mgr','nina','wendy','wes','other'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t128.test');
  end loop;
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values
    (t.id('owner'), r1, t.id('auth:owner'), 'E1', 'Olivia Owner',  t.id('roleOwner'),   'owner@t128.test'),
    (t.id('carl'),  r1, t.id('auth:carl'),  'E2', 'Carl Cashier',  t.id('roleCashier'), 'carl@t128.test'),
    (t.id('mgr'),   r1, t.id('auth:mgr'),   'E3', 'Maya Manager',  t.id('roleMgr'),     'mgr@t128.test'),
    (t.id('nina'),  r1, t.id('auth:nina'),  'E4', 'Nina Nobody',   t.id('roleNobody'),  'nina@t128.test'),
    (t.id('wendy'), r1, t.id('auth:wendy'), 'E5', 'Wendy Waiter',  t.id('roleCashier'), 'wendy@t128.test'),
    (t.id('wes'),   r1, t.id('auth:wes'),   'E6', 'Wes Waiter',    t.id('roleCashier'), 'wes@t128.test'),
    (t.id('other'), r2, t.id('auth:other'), 'E7', 'Other Owner',   t.id('roleOwner2'),  'other@t128.test');
  -- Carl and Maya work only in outlet A
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (t.id('carl'), a, r1), (t.id('mgr'), a, r1);

  -- menu
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price, is_available, is_charge, deleted_at) values
    (t.id('burger'), r1, cat, tg, 'Burger', 100, true, false, null),
    (t.id('pizza'),  r1, cat, tg, 'Pizza', 300, true, false, null),
    (t.id('soup'),   r1, cat, tg, 'Soup', 80, true, false, null),       -- switched off at B only
    (t.id('tea'),    r1, cat, tg, 'Tea', 20, true, false, null),        -- switched off at A and B
    (t.id('coffee'), r1, cat, tg, 'Coffee', 100, true, false, null),    -- never off
    (t.id('salad'),  r1, cat, tg, 'Salad', 90, true, false, null),      -- switched off at A only
    (t.id('pasta'),  r1, cat, tg, 'Pasta', 150, true, false, null),     -- parent of a size: not an item itself
    (t.id('hidden'), r1, cat, tg, 'Hidden dish', 50, false, false, null),   -- not available
    (t.id('gone'),   r1, cat, tg, 'Deleted dish', 50, true, false, now()),  -- deleted
    (t.id('charge'), r1, cat, tg, 'Packing charge', 10, true, true, null),  -- extra charge
    (t.id('burger2'),r2, cat2, tg2, 'Burger', 100, true, false, null);
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price, parent_id, variant_name)
    values (t.id('pastasm'), r1, cat, tg, 'Pasta Small', 120, t.id('pasta'), 'Small');
  insert into public.branch_prices (restaurant_id, branch_id, product_id, is_available) values
    (r1, b, t.id('soup'), false), (r1, a, t.id('tea'), false), (r1, b, t.id('tea'), false), (r1, a, t.id('salad'), false);
end $$;

-- orders: (key, outlet, bill, date, status, comp, cashier, waiter, covers, subtotal, discount, grand, merged_into)
create function t.mk_order(k text, p_branch text, p_date date, p_status text, p_comp text, p_cashier text, p_waiter text, p_covers int,
                           p_sub numeric, p_disc numeric, p_grand numeric, p_merged text default null, p_rest text default 'rest1') returns void language plpgsql as $$
begin
  insert into public.orders (id, restaurant_id, branch_id, bill_number, order_type, cashier_id, waiter_id, currency_code, client_created_at,
                             business_date, status, payment_status, comp_kind, comp_reason, comp_by, covers, subtotal, discount_total, grand_total,
                             merged_into, voided_by, void_reason)
  values (t.id(k), t.id(p_rest), t.id(p_branch), upper(k), 'dine_in', t.id(p_cashier), case when p_waiter is null then null else t.id(p_waiter) end, 'INR', p_date::timestamptz,
          p_date, p_status, case when p_status = 'completed' then 'paid' else 'unpaid' end,
          p_comp, case when p_comp is null then null else 'test reason' end, case when p_comp is null then null else t.id('owner') end,
          p_covers, p_sub, p_disc, p_grand,
          case when p_merged is null then null else t.id(p_merged) end,
          case when p_status = 'voided' then t.id('owner') end, case when p_status = 'voided' then 'test void' end);
end $$;
create function t.mk_item(k text, p_order text, p_prod text, p_name text, p_qty numeric, p_unit numeric, p_cancelled boolean default false, p_rest text default 'rest1') returns void language plpgsql as $$
begin
  insert into public.order_items (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, line_subtotal, line_total, cancelled_at)
  values (t.id(k), t.id(p_rest), t.id(p_order), t.id(p_prod), p_name, p_unit, p_qty, p_qty * p_unit, p_qty * p_unit, case when p_cancelled then now() end);
end $$;

select t.mk_order('o1', 'outA', '2026-10-20', 'completed', null, 'carl', 'wendy', 2, 500, 50, 450);
select t.mk_item('i1a', 'o1', 'burger', 'Burger', 2, 100), t.mk_item('i1b', 'o1', 'pizza', 'Pizza', 1, 300);
select t.mk_order('o2', 'outA', '2026-10-21', 'completed', null, 'carl', null, null, 200, 0, 200);
select t.mk_item('i2a', 'o2', 'burger', 'Burger', 2, 100), t.mk_item('i2b', 'o2', 'soup', 'Soup', 1, 80, true);       -- soup line cancelled
select t.mk_order('o3', 'outA', '2026-10-21', 'completed', 'complimentary', 'carl', 'wendy', 2, 300, 100, 0);          -- complimentary bill
select t.mk_item('i3a', 'o3', 'pizza', 'Pizza', 1, 300);
select t.mk_order('o4', 'outA', '2026-10-21', 'voided', null, 'carl', 'wendy', 3, 1000, 100, 1000);                    -- voided bill
select t.mk_item('i4a', 'o4', 'pizza', 'Pizza', 3, 300), t.mk_item('i4b', 'o4', 'soup', 'Soup', 1, 100);
select t.mk_order('o5', 'outA', '2026-10-19', 'completed', null, 'carl', 'wendy', 2, 500, 50, 450);                    -- day before the range
select t.mk_item('i5a', 'o5', 'burger', 'Burger', 5, 100);
select t.mk_order('o6', 'outA', '2026-10-20', 'completed', null, 'carl', 'wendy', 2, 400, 40, 360, 'o1');              -- merged into o1
select t.mk_item('i6a', 'o6', 'burger', 'Burger', 4, 100);
select t.mk_order('o9', 'outA', '2026-10-22', 'completed', null, 'carl', null, null, 0, 30, 0);                        -- zero subtotal with a discount
select t.mk_order('o7', 'outB', '2026-10-20', 'completed', null, 'owner', 'wes', 4, 800, 200, 600);
select t.mk_item('i7a', 'o7', 'burger', 'Burger', 1, 100), t.mk_item('i7b', 'o7', 'pizza', 'Pizza', 2, 300), t.mk_item('i7c', 'o7', 'coffee', 'Coffee', 1, 100);
select t.mk_order('o8', 'outB', '2026-10-22', 'completed', null, 'owner', 'wendy', 3, 400, 40, 360);
select t.mk_item('i8a', 'o8', 'burger', 'Burger', 4, 100);
select t.mk_order('o10', 'outB', '2026-10-23', 'completed', null, 'owner', 'wes', 2, 2700, 0, 2700);                   -- day after the range
select t.mk_item('i10a', 'o10', 'pizza', 'Pizza', 9, 300);
select t.mk_order('o11', 'outC', '2026-10-21', 'completed', null, 'other', 'other', 2, 100, 10, 90, null, 'rest2');    -- another restaurant
select t.mk_item('i11a', 'o11', 'burger2', 'Burger', 1, 100, false, 'rest2');
reset session_replication_role;
update public.users set current_branch_id = t.id('outA'), all_outlets = false where id = t.id('owner');
\set F '\'2026-10-20\'::date, \'2026-10-22\'::date'

-- ---------------------------------------------------------------- 0. the problem this fixes: direct table reads follow only the current outlet
update public.users set all_outlets = true, current_branch_id = t.id('outA') where id = t.id('owner');
select t.as_('owner');
select count(*) as n_direct from public.orders where business_date between '2026-10-20' and '2026-10-22' and status = 'completed' \gset
select (public.my_outlets() ->> 'all_outlets')::boolean as is_all \gset
reset role;
select t.eq('0a. owner on All outlets: my_outlets says all_outlets', to_jsonb(:'is_all'::boolean), 'true');
select t.eq('0b. (the bug) a direct orders read still shows only outlet A bills: o1,o2,o3,o6,o9 = 5', to_jsonb(:n_direct), '5');

-- ---------------------------------------------------------------- 1. OWNER, ALL OUTLETS
select t.as_('owner');
select public.report_popular_items(:F) as j \gset
reset role; select t.same('1.1 popular, All outlets: Burger 9/900, Pizza 4/1200, Coffee 1/100 (voided, merged, cancelled line, other days, other restaurant left out; complimentary Pizza counted)', :'j'::jsonb,
  format('[{"product_id":"%s","name":"Burger","units":9,"amount":900},{"product_id":"%s","name":"Pizza","units":4,"amount":1200},{"product_id":"%s","name":"Coffee","units":1,"amount":100}]', t.id('burger'), t.id('pizza'), t.id('coffee')));
select t.as_('owner');
select public.report_unsold_items(:F) as j \gset
reset role;
select t.same('1.2a unsold, All outlets: Pasta Small, Salad (off at A only), Soup (cancelled line only; off at B only). Not Tea (off everywhere), Pasta (parent), Hidden, Deleted, Packing charge', t.names(:'j'::jsonb -> 'unsold', 'name'), '["Pasta Small","Salad","Soup"]');
select t.same('1.2b sold_least, All outlets: Coffee 1, Pizza 4, Burger 9', :'j'::jsonb -> 'sold_least',
  format('[{"product_id":"%s","name":"Coffee","units":1,"amount":100},{"product_id":"%s","name":"Pizza","units":4,"amount":1200},{"product_id":"%s","name":"Burger","units":9,"amount":900}]', t.id('coffee'), t.id('pizza'), t.id('burger')));
select t.as_('owner');
select public.report_waiter_sales(:F) as j \gset
reset role;
select t.same('1.3 waiter sales, All outlets (complimentary o3, voided o4, merged o6, other days left out)', :'j'::jsonb,
  format('[{"branch_id":"%1$s","outlet_name":"Outlet B","user_id":"%2$s","staff_name":"Wes Waiter","bills":1,"covers":4,"sales":600},
           {"branch_id":"%3$s","outlet_name":"Outlet A","user_id":"%4$s","staff_name":"Wendy Waiter","bills":1,"covers":2,"sales":450},
           {"branch_id":"%1$s","outlet_name":"Outlet B","user_id":"%4$s","staff_name":"Wendy Waiter","bills":1,"covers":3,"sales":360},
           {"branch_id":"%3$s","outlet_name":"Outlet A","user_id":"%5$s","staff_name":"Carl Cashier","bills":2,"covers":null,"sales":200}]',
    t.id('outB'), t.id('wes'), t.id('outA'), t.id('wendy'), t.id('carl')));
select t.as_('owner');
select public.report_discounts(:F) as j \gset
reset role;
select t.same('1.4a discounts by_cashier, All outlets', :'j'::jsonb -> 'by_cashier',
  format('[{"branch_id":"%1$s","outlet_name":"Outlet B","user_id":"%2$s","name":"Olivia Owner","bills":2,"total":240,"max_pct":25},
           {"branch_id":"%3$s","outlet_name":"Outlet A","user_id":"%4$s","name":"Carl Cashier","bills":2,"total":80,"max_pct":10}]', t.id('outB'), t.id('owner'), t.id('outA'), t.id('carl')));
select t.same('1.4b discounts by_day (zero-subtotal bill gives 0 %, no division error)', :'j'::jsonb -> 'by_day',
  '[{"business_date":"2026-10-20","bills":2,"total":250,"max_pct":25},{"business_date":"2026-10-22","bills":2,"total":70,"max_pct":10}]');
select t.same('1.4c discounts by_outlet', :'j'::jsonb -> 'by_outlet',
  format('[{"branch_id":"%s","outlet_name":"Outlet B","bills":2,"total":240,"max_pct":25},{"branch_id":"%s","outlet_name":"Outlet A","bills":2,"total":80,"max_pct":10}]', t.id('outB'), t.id('outA')));

-- ---------------------------------------------------------------- 2. OWNER, OUTLET A ONLY
reset role;
update public.users set all_outlets = false, current_branch_id = t.id('outA') where id = t.id('owner');
select t.as_('owner');
select public.report_popular_items(:F) as p, public.report_unsold_items(:F) as u, public.report_waiter_sales(:F) as w, public.report_discounts(:F) as d \gset
reset role;
select t.same('2.1 popular, outlet A: Burger 4/400, Pizza 2/600', :'p'::jsonb,
  format('[{"product_id":"%s","name":"Burger","units":4,"amount":400},{"product_id":"%s","name":"Pizza","units":2,"amount":600}]', t.id('burger'), t.id('pizza')));
select t.same('2.2a unsold, outlet A: Coffee, Pasta Small, Soup (Salad and Tea are switched off at A)', t.names(:'u'::jsonb -> 'unsold', 'name'), '["Coffee","Pasta Small","Soup"]');
select t.same('2.2b sold_least, outlet A: Pizza 2, Burger 4', t.names(:'u'::jsonb -> 'sold_least', 'name'), '["Pizza","Burger"]');
select t.same('2.3 waiter sales, outlet A only: Wendy 450, Carl 200 (2 bills)', (select jsonb_agg(jsonb_build_object('n', e ->> 'staff_name', 'o', e ->> 'outlet_name', 'bills', e -> 'bills', 'sales', e -> 'sales')) from jsonb_array_elements(:'w'::jsonb) e),
  '[{"n":"Wendy Waiter","o":"Outlet A","bills":1,"sales":450},{"n":"Carl Cashier","o":"Outlet A","bills":2,"sales":200}]');
select t.same('2.4 discounts, outlet A only: Carl 2 bills 80 (10 % and the zero-subtotal bill), one outlet row, two days',
  jsonb_build_object('c', t.names(:'d'::jsonb -> 'by_cashier', 'name'), 'o', t.names(:'d'::jsonb -> 'by_outlet', 'outlet_name'), 'days', :'d'::jsonb -> 'by_day'),
  '{"c":["Carl Cashier"],"o":["Outlet A"],"days":[{"business_date":"2026-10-20","bills":1,"total":50,"max_pct":10},{"business_date":"2026-10-22","bills":1,"total":30,"max_pct":0}]}');

-- ---------------------------------------------------------------- 3. OWNER, OUTLET B ONLY
reset role;
update public.users set current_branch_id = t.id('outB') where id = t.id('owner');
select t.as_('owner');
select public.report_popular_items(:F) as p, public.report_unsold_items(:F) as u, public.report_waiter_sales(:F) as w \gset
reset role;
select t.same('3.1 popular, outlet B: Burger 5/500, Pizza 2/600, Coffee 1/100', (select jsonb_agg(jsonb_build_array(e ->> 'name', e -> 'units', e -> 'amount')) from jsonb_array_elements(:'p'::jsonb) e), '[["Burger",5,500],["Pizza",2,600],["Coffee",1,100]]');
select t.same('3.2 unsold, outlet B: Pasta Small, Salad (Soup and Tea are switched off at B)', t.names(:'u'::jsonb -> 'unsold', 'name'), '["Pasta Small","Salad"]');
select t.same('3.3 waiter sales, outlet B: Wes 600, Wendy 360', t.names(:'w'::jsonb, 'staff_name'), '["Wes Waiter","Wendy Waiter"]');

-- ---------------------------------------------------------------- 4. RESTRICTED USERS (work only in outlet A)
-- Carl (sales right only), picker at its default
select t.as_('carl');
select public.report_popular_items(:F) as p, public.report_waiter_sales(:F) as w, public.report_unsold_items(:F) as u \gset
reset role;
select t.same('4.1 Carl: popular items are outlet A only (never B)', (select jsonb_agg(e ->> 'name' || ':' || (e ->> 'units')) from jsonb_array_elements(:'p'::jsonb) e), '["Burger:4.00","Pizza:2.00"]');
select t.same('4.2 Carl: waiter sales has outlet A rows only', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'w'::jsonb) e), '["Outlet A"]');
-- Carl tries to reach All outlets through the app function ...
select t.as_('carl');
select t.err('4.3 Carl cannot choose All outlets', format('select public.set_current_outlet(%L, true)', t.id('outA')), 'Only the owner can see all outlets together');
select t.err('4.4 Carl cannot switch to outlet B', format('select public.set_current_outlet(%L, false)', t.id('outB')), 'You do not work in that outlet');
reset role;
-- ... or even if the all-outlets flag is forced on his row, the reports stay on his outlet
update public.users set all_outlets = true, current_branch_id = t.id('outB') where id = t.id('carl');
select t.as_('carl');
select public.report_waiter_sales(:F) as w, public.report_popular_items(:F) as p, public.report_unsold_items(:F) as u \gset
reset role;
select t.same('4.5 Carl with the all-outlets flag forced on and current outlet forced to B: still outlet A only', jsonb_build_object('outlets', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'w'::jsonb) e), 'burger', (:'p'::jsonb -> 0 -> 'units')), '{"outlets":["Outlet A"],"burger":4}');
update public.users set all_outlets = false, current_branch_id = null where id = t.id('carl');
-- Maya (manager restricted to A) may see financial reports, still only outlet A
update public.users set all_outlets = true where id = t.id('mgr');
select t.as_('mgr');
select public.report_discounts(:F) as d \gset
reset role;
select t.same('4.6 Maya (restricted manager, all-outlets flag forced on): discounts for outlet A only', t.names(:'d'::jsonb -> 'by_outlet', 'outlet_name'), '["Outlet A"]');
update public.users set all_outlets = false where id = t.id('mgr');

-- ---------------------------------------------------------------- 5. PERMISSIONS
select t.as_('carl');
select t.err('5.1 Carl (sales only): discount summary refused', format('select public.report_discounts(%s)', :'F'), 'You do not have the right to see financial reports.');
select t.err('5.2 Carl may use popular items', format('select public.report_popular_items(%s)', :'F'), 'NO ERROR');
select t.as_('nina');
select t.err('5.3 Nina (no report rights): popular items refused', format('select public.report_popular_items(%s)', :'F'), 'report.view_sales');
select t.err('5.4 Nina: unsold items refused', format('select public.report_unsold_items(%s)', :'F'), 'report.view_sales');
select t.err('5.5 Nina: waiter sales refused', format('select public.report_waiter_sales(%s)', :'F'), 'report.view_sales');
select t.err('5.6 Nina: discounts refused', format('select public.report_discounts(%s)', :'F'), 'report.view_sales');
select t.as_('mgr');
select t.err('5.7 Maya (sales + financial): discount summary allowed', format('select public.report_discounts(%s)', :'F'), 'NO ERROR');
select set_config('request.jwt.claim.sub', '', false);
select t.err('5.8 signed in as nobody (no user): refused', format('select public.report_waiter_sales(%s)', :'F'), 'not signed in');
reset role;
set role anon;
select t.err('5.9 the anon role has no execute right', format('select public.report_popular_items(%s)', :'F'), 'permission denied');
reset role;
select t.eq('5.10 grants: authenticated can execute, anon and public cannot (4 functions)',
  (select jsonb_build_object('auth', bool_and(has_function_privilege('authenticated', p.oid, 'execute')), 'anon', bool_or(has_function_privilege('anon', p.oid, 'execute')),
          'public', bool_or(exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)))
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('report_popular_items','report_unsold_items','report_waiter_sales','report_discounts')),
  '{"auth":true,"anon":false,"public":false}');
select t.eq('5.11 all four are STABLE SECURITY DEFINER with a fixed search_path',
  (select jsonb_build_object('n', count(*), 'stable', bool_and(provolatile = 's'), 'definer', bool_and(prosecdef), 'path', bool_and(proconfig::text like '%search_path=public, pg_temp%'))
     from pg_proc where pronamespace = 'public'::regnamespace and proname in ('report_popular_items','report_unsold_items','report_waiter_sales','report_discounts')),
  '{"n":4,"stable":true,"definer":true,"path":true}');

-- ---------------------------------------------------------------- 6. DATE RANGE CHECKS and EMPTY RANGES
select t.as_('owner');
select t.err('6.1 reversed range', 'select public.report_popular_items(''2026-10-22'', ''2026-10-20'')', 'Choose a valid date range.');
select t.err('6.2 null date', 'select public.report_waiter_sales(null, ''2026-10-20'')', 'Choose a valid date range.');
select t.err('6.3 367 days refused', 'select public.report_discounts(''2025-10-01'', ''2026-10-03'')', 'one year or less');
select t.err('6.4 366 days allowed', 'select public.report_unsold_items(''2025-10-01'', ''2026-10-02'')', 'NO ERROR');
select public.report_popular_items('2026-01-01', '2026-01-02') as p, public.report_waiter_sales('2026-01-01', '2026-01-02') as w, public.report_discounts('2026-01-01', '2026-01-02') as d, public.report_unsold_items('2026-01-01', '2026-01-02') as u \gset
reset role;
select t.same('6.5 empty range: empty lists, not null (unsold lists all 5 items on at outlet B, the current outlet of the owner, because none sold)', jsonb_build_object('p', :'p'::jsonb, 'w', :'w'::jsonb, 'd', :'d'::jsonb, 'unsold_n', jsonb_array_length(:'u'::jsonb -> 'unsold'), 'least', :'u'::jsonb -> 'sold_least'),
  '{"p":[],"w":[],"d":{"by_cashier":[],"by_day":[],"by_outlet":[]},"unsold_n":5,"least":[]}');

-- ---------------------------------------------------------------- 7. OTHER RESTAURANT never leaks, and cannot see ours
update public.users set all_outlets = true, current_branch_id = t.id('outC') where id = t.id('other');
select t.as_('other');
select public.report_popular_items(:F) as p, public.report_waiter_sales(:F) as w \gset
reset role;
select t.same('7.1 the other restaurant sees only its own Burger x1 and its own outlet C', jsonb_build_object('p', (select jsonb_agg(e ->> 'name' || ':' || (e ->> 'units')) from jsonb_array_elements(:'p'::jsonb) e), 'o', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'w'::jsonb) e)),
  '{"p":["Burger:1.00"],"o":["Outlet C"]}');

-- ---------------------------------------------------------------- 8. nothing was written
select t.eq('8.1 no report function left a temp table behind', (select to_jsonb(count(*)) from pg_class where relname like '\_rep\_%' and relpersistence = 't'), '0');

-- ---------------------------------------------------------------- result
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
select case when :failed > 0 then 1/0 end as stop_if_failed;
