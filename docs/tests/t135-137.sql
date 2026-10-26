-- t135-137.sql: proves migrations 135 (log_print), 136 (bulk price change) and 137 (copy rights / access).
-- Run as a superuser (it creates its own fixtures and impersonates users with SET ROLE authenticated + JWT claims).
-- Run it on a FRESH scratch database (docs/tests/run-t135137.sh builds one). Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
grant usage on schema t to public; grant all on t.res to public; grant usage on sequence t.res_n_seq to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t135137:' || p)::uuid $$;
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

-- q = compare any value (number, bool, jsonb) with an expected JSON text; numbers compare as numbers
create function t.q(p_label text, p_actual anyelement, p_expected text) returns void language sql as $$
  select t.eq(p_label, t.norm(to_jsonb(p_actual)), t.norm(p_expected::jsonb)) $$;

-- ---------------------------------------------------------------- fixtures
set session_replication_role = replica;      -- orders / tickets are written straight into the tables
do $$
declare r1 uuid := t.id('rest1'); r2 uuid := t.id('rest2'); a uuid := t.id('outA'); b uuid := t.id('outB'); c uuid := t.id('outC'); x text;
begin
  insert into public.restaurants (id, legal_name, trading_name, country_code, currency_code, timezone, edition)
    values (r1, 'Test One Pvt Ltd', 'Test One', 'IN', 'INR', 'Asia/Kolkata', 'professional'),
           (r2, 'Test Two Pvt Ltd', 'Test Two', 'IN', 'INR', 'Asia/Kolkata', 'professional');
  insert into public.restaurant_modules (restaurant_id, module_key) values (r1, 'owner_app');
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone, created_at) values (a, r1, 'Outlet A', 'A', 'IN', 'Asia/Kolkata', now() - interval '2 days');
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone, created_at) values (b, r1, 'Outlet B', 'B', 'IN', 'Asia/Kolkata', now() - interval '1 day');
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone) values (c, r2, 'Outlet C', 'C', 'IN', 'Asia/Kolkata');
  insert into public.tax_groups (id, restaurant_id, name) values (t.id('tax1'), r1, 'GST'), (t.id('tax2'), r2, 'GST');
  insert into public.categories (id, restaurant_id, name) values (t.id('catFood'), r1, 'Food'), (t.id('catDrinks'), r1, 'Drinks'), (t.id('catFood2'), r2, 'Food');
  insert into public.categories (id, restaurant_id, name, parent_id) values (t.id('catStart'), r1, 'Starters', t.id('catFood'));
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values
    (t.id('burger'), r1, t.id('catFood'), t.id('tax1'), 'Burger', 100), (t.id('pizza'), r1, t.id('catFood'), t.id('tax1'), 'Pizza', 300),
    (t.id('soup'), r1, t.id('catStart'), t.id('tax1'), 'Soup', 80), (t.id('tea'), r1, t.id('catDrinks'), t.id('tax1'), 'Tea', 20),
    (t.id('coffee'), r1, t.id('catDrinks'), t.id('tax1'), 'Coffee', 100), (t.id('burger2'), r2, t.id('catFood2'), t.id('tax2'), 'Burger', 100);
  insert into public.branch_prices (restaurant_id, branch_id, product_id, price, is_available) values
    (r1, a, t.id('burger'), 110, null), (r1, b, t.id('pizza'), 320, null), (r1, a, t.id('tea'), null, false);
  insert into public.roles (id, restaurant_id, name, is_system) values
    (t.id('roleOwner'), r1, 'Owner', true), (t.id('roleMgr'), r1, 'Manager', false), (t.id('roleCashier'), r1, 'Cashier', false),
    (t.id('roleSteward'), r1, 'Steward', false), (t.id('roleNobody'), r1, 'Nobody', false),
    (t.id('roleCustom'), r1, 'Custom', false), (t.id('roleTemplate'), r1, 'Template', false), (t.id('roleOwner2'), r2, 'Owner', true), (t.id('roleOther2'), r2, 'Other', false);
  insert into public.role_permissions (role_id, permission_key) values
    (t.id('roleOwner'), 'order.reprint'), (t.id('roleOwner'), 'menu.price_change'), (t.id('roleOwner'), 'user.manage'), (t.id('roleOwner'), 'menu.manage'), (t.id('roleOwner'), 'order.create'),
    (t.id('roleMgr'), 'order.reprint'), (t.id('roleMgr'), 'menu.price_change'), (t.id('roleMgr'), 'user.manage'), (t.id('roleMgr'), 'menu.manage'), (t.id('roleMgr'), 'order.create'),
    (t.id('roleCashier'), 'order.reprint'), (t.id('roleCashier'), 'order.create'),
    (t.id('roleSteward'), 'order.create'),
    (t.id('roleCustom'), 'order.create'), (t.id('roleCustom'), 'shift.open'),
    (t.id('roleTemplate'), 'order.create'), (t.id('roleTemplate'), 'order.discount'), (t.id('roleTemplate'), 'payment.take'),
    (t.id('roleOwner2'), 'user.manage'), (t.id('roleOther2'), 'order.create');
  foreach x in array array['owner','mgr','carl','stan','nina','wes','other'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t135137.test');
  end loop;
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values
    (t.id('owner'), r1, t.id('auth:owner'), 'E1', 'Olivia Owner',  t.id('roleOwner'),   'owner@t135137.test'),
    (t.id('mgr'),   r1, t.id('auth:mgr'),   'E2', 'Maya Manager',  t.id('roleMgr'),     'mgr@t135137.test'),
    (t.id('carl'),  r1, t.id('auth:carl'),  'E3', 'Carl Cashier',  t.id('roleCashier'), 'carl@t135137.test'),
    (t.id('stan'),  r1, t.id('auth:stan'),  'E4', 'Stan Steward',  t.id('roleSteward'), 'stan@t135137.test'),
    (t.id('nina'),  r1, t.id('auth:nina'),  'E5', 'Nina Nobody',   t.id('roleNobody'),  'nina@t135137.test'),
    (t.id('wes'),   r1, t.id('auth:wes'),   'E6', 'Wes Waiter',    t.id('roleSteward'), 'wes@t135137.test'),
    (t.id('other'), r2, t.id('auth:other'), 'E7', 'Other Owner',   t.id('roleOwner2'),  'other@t135137.test');
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (t.id('carl'), a, r1), (t.id('mgr'), a, r1);
  insert into public.payment_methods (id, restaurant_id, name, kind) values (t.id('pmCash'), r1, 'Cash', 'cash');
  -- three bills: o1 (outlet A), o3 (outlet B), o4 (the other restaurant); two kitchen tickets on o1, one on o3
  insert into public.orders (id, restaurant_id, branch_id, bill_number, order_type, cashier_id, currency_code, client_created_at, status, payment_status, subtotal, grand_total) values
    (t.id('o1'), r1, a, 'B-1', 'takeaway', t.id('carl'), 'INR', now(), 'completed', 'unpaid', 100, 100),
    (t.id('o2'), r1, a, 'B-2', 'takeaway', t.id('carl'), 'INR', now(), 'completed', 'unpaid', 100, 100),
    (t.id('o3'), r1, b, 'B-3', 'takeaway', t.id('carl'), 'INR', now(), 'completed', 'unpaid', 100, 100),
    (t.id('o4'), r2, c, 'B-4', 'takeaway', t.id('other'), 'INR', now(), 'completed', 'unpaid', 100, 100);
  insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, station, status, client_created_at, created_at) values
    (t.id('k1'), r1, a, t.id('o1'), 'K-1', 'Kitchen', 'new', now() - interval '3 minutes', now() - interval '3 minutes'),
    (t.id('k2'), r1, a, t.id('o1'), 'K-2', 'Kitchen', 'new', now() - interval '2 minutes', now() - interval '2 minutes'),
    (t.id('k3'), r1, a, t.id('o2'), 'K-3', 'Kitchen', 'new', now(), now()),
    (t.id('k4'), r1, b, t.id('o3'), 'K-4', 'Kitchen', 'new', now(), now());
  -- an OPEN bill that holds a Burger at the old price: a bulk price change must never touch it
  insert into public.order_items (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, line_subtotal, line_total, net_amount)
    values (t.id('oi1'), r1, t.id('o2'), t.id('burger'), 'Burger', 100, 1, 100, 100, 100);
end $$;
set session_replication_role = default;      -- from here the real triggers run (price guard, price history)

select md5(row(o.*)::text) as o1_before from public.orders o where id = t.id('o1') \gset

-- ================================================================ 135 log_print
select t.as_('stan');
select public.log_print('bill', t.id('o1')) as p1 \gset
select t.same('1.1 first bill print by a Steward (no reprint right) works silently, logged as bill.print #1', :'p1'::jsonb,
  '{"kind":"bill","action":"bill.print","reprint":false,"print_no":1}');
select t.err('1.2 the second print of the same bill is a reprint: a Steward without the right is refused, asked for the right (order.reprint)',
  $q$ select public.log_print('bill', t.id('o1')) $q$, '(order.reprint)');
reset role;
select t.q('1.3 the refused reprint wrote nothing (still one print row)',
  (select to_jsonb(count(*)) from public.audit_logs where entity_id = t.id('o1') and action in ('bill.print', 'bill.reprint')), '1');
-- a manager PIN approval for this Steward (what approve_with_pin writes)
insert into public.approvals (restaurant_id, requested_by, approved_by, permission_key) values (t.id('rest1'), t.id('stan'), t.id('mgr'), 'order.reprint');
select t.as_('stan');
select public.log_print('bill', t.id('o1')) as p2 \gset
reset role;
select t.same('1.4 with a manager PIN approval the Steward may reprint: logged as bill.reprint #2', :'p2'::jsonb,
  '{"kind":"bill","action":"bill.reprint","reprint":true,"print_no":2}');
select t.q('1.5 the approval was used up (one reprint per approval)', (select to_jsonb(used_at is not null) from public.approvals where requested_by = t.id('stan') and permission_key = 'order.reprint'), 'true');
select t.as_('stan');
select t.err('1.6 a third reprint without a new approval is refused again', $q$ select public.log_print('bill', t.id('o1')) $q$, '(order.reprint)');
select t.as_('carl');
select public.log_print('bill', t.id('o1')) as p3 \gset
reset role;
select t.same('1.7 a Cashier (has the right) reprints without a PIN: print #3', :'p3'::jsonb, '{"kind":"bill","action":"bill.reprint","reprint":true,"print_no":3}');
select t.q('1.8 audit trail for o1: one bill.print and two bill.reprint',
  (select jsonb_build_object('print', count(*) filter (where action = 'bill.print'), 'reprint', count(*) filter (where action = 'bill.reprint')) from public.audit_logs where entity_id = t.id('o1')),
  '{"print":1,"reprint":2}');
select t.q('1.9 the reprint row says who did it and which print it was',
  (select to_jsonb(array_agg((u.full_name || ' #' || (a.new_value ->> 'print_no')) order by a.id)) from public.audit_logs a join public.users u on u.id = a.user_id where a.entity_id = t.id('o1') and a.action = 'bill.reprint'),
  '["Stan Steward #2","Carl Cashier #3"]');
select t.as_('stan');
select t.err('1.10 a KOT reprint by a Steward is refused (needs the right or a PIN)', $q$ select public.log_print('kot', t.id('o1'), array[t.id('k1')]) $q$, '(order.reprint)');
select t.as_('carl');
select public.log_print('kot', t.id('o1'), array[t.id('k1'), t.id('k2')]) as k1 \gset
reset role;
select t.same('1.11 a Cashier reprints two tickets: kot.reprint with both ticket numbers', :'k1'::jsonb, '{"kind":"kot","action":"kot.reprint","reprint":true,"tickets":["K-1","K-2"]}');
select t.q('1.12 the kot.reprint row carries ticket ids',
  (select jsonb_array_length(new_value -> 'ticket_ids') from public.audit_logs where action = 'kot.reprint' and entity_id = t.id('o1')), '2');
select t.as_('carl');
select public.log_print('kot', t.id('o1')) as k2 \gset
reset role;
select t.same('1.13 a KOT reprint with no ticket list reprints every ticket of the bill', :'k2'::jsonb->'tickets', '["K-1","K-2"]');
select t.as_('carl');
select t.err('1.14 a ticket that belongs to another bill is refused', $q$ select public.log_print('kot', t.id('o1'), array[t.id('k3')]) $q$, 'does not belong to this bill');
select t.err('1.15 a bill from another outlet is not found', $q$ select public.log_print('bill', t.id('o3')) $q$, 'Bill not found');
select t.err('1.16 a bill of another restaurant is not found', $q$ select public.log_print('bill', t.id('o4')) $q$, 'Bill not found');
select t.err('1.17 an unknown kind is refused', $q$ select public.log_print('receipt', t.id('o1')) $q$, 'bill or kot');
select t.err('1.18 an unknown bill is not found', $q$ select public.log_print('bill', gen_random_uuid()) $q$, 'Bill not found');
reset role; select set_config('request.jwt.claim.sub', '', false); set role authenticated;
select t.err('1.19 nobody signed in is refused', $q$ select public.log_print('bill', t.id('o1')) $q$, 'not signed in');
reset role;
select t.q('1.20 printing never changes the bill', (select to_jsonb(md5(row(o.*)::text) = :'o1_before') from public.orders o where id = t.id('o1')), 'true');
-- explicit reprint flag (QA M2): a real reprint of a bill whose first print was never logged must not look original
select t.as_('stan');
select t.err('1.22 p_is_reprint = true on a bill with no logged print is still a reprint: a Steward without the right is refused', $q$ select public.log_print('bill', t.id('o2'), null, true) $q$, '(order.reprint)');
reset role;
select t.q('1.23 the refused declared reprint wrote nothing', (select to_jsonb(count(*)) from public.audit_logs where entity_id = t.id('o2') and action in ('bill.print', 'bill.reprint')), '0');
select t.as_('carl');
select public.log_print('bill', t.id('o2'), null, true) as p4 \gset
reset role;
select t.same('1.24 a Cashier declaring a reprint gets bill.reprint, print #2 (the unlogged original counts as #1)', :'p4'::jsonb, '{"kind":"bill","action":"bill.reprint","reprint":true,"print_no":2}');
select t.as_('stan');
select t.err('1.25 p_is_reprint = false cannot skip the check once a print is logged', $q$ select public.log_print('bill', t.id('o2'), null, false) $q$, '(order.reprint)');
reset role;
select t.as_('carl');
select t.same('1.26 null / omitted flag still means the original rule: a fresh bill (o1 untouched here) is not affected; o2 now counts as printed',
  (public.log_print('bill', t.id('o2'), null, null)->>'print_no')::int::text::jsonb, '3');
reset role;
select t.q('1.27 the old 3-argument log_print is gone, one log_print remains', (select to_jsonb(count(*)) from pg_proc where proname = 'log_print' and pronamespace = 'public'::regnamespace), '1');
select t.q('1.21 the print log is also written for the Owner-less default: Stewards have no order.reprint (fixture) while Cashier/Manager/Owner do',
  (select to_jsonb(array_agg(r.name order by r.name)) from public.roles r join public.role_permissions rp on rp.role_id = r.id where rp.permission_key = 'order.reprint' and r.restaurant_id = t.id('rest1')),
  '["Cashier","Manager","Owner"]');

-- ================================================================ 136 bulk price
select t.as_('carl');
select t.err('2.1 a Cashier cannot preview a bulk price change', $q$ select public.bulk_price_preview('percent', 10, 1, jsonb_build_object('category_ids', jsonb_build_array(t.id('catFood')))) $q$, '(menu.price_change)');
select t.err('2.2 a Cashier cannot apply one', $q$ select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('all', true), true, 'because') $q$, '(menu.price_change)');
select t.as_('mgr');
select public.bulk_price_preview('percent', 10, 1, jsonb_build_object('category_ids', jsonb_build_array(t.id('catFood'))), true) as pv \gset
reset role;
select t.same('2.3 preview +10% on Food (incl. its sub-category Starters), rounding 1: 3 base + 2 outlet lines', 
  jsonb_build_object('total', :'pv'::jsonb -> 'total_lines', 'base', :'pv'::jsonb -> 'base_lines', 'branch', :'pv'::jsonb -> 'branch_lines',
    'rows', (select jsonb_agg(jsonb_build_array(e ->> 'name', e ->> 'scope', e -> 'old_price', e -> 'new_price') order by e ->> 'name', e ->> 'scope') from jsonb_array_elements(:'pv'::jsonb -> 'lines') e)),
  '{"total":5,"base":3,"branch":2,"rows":[["Burger","base",100,110],["Burger","branch",110,121],["Pizza","base",300,330],["Pizza","branch",320,352],["Soup","base",80,88]]}');
select t.q('2.4 preview wrote nothing: prices, batches, history and audit unchanged',
  jsonb_build_object('burger', (select price from public.products where id = t.id('burger')), 'batches', (select count(*) from public.price_change_batches),
                     'audit', (select count(*) from public.audit_logs where action like 'menu.bulk%')), '{"burger":100.00,"batches":0,"audit":0}');
select t.as_('mgr');
select public.bulk_price_preview('percent', 10, 1, jsonb_build_object('category_ids', jsonb_build_array(t.id('catFood'))), false) as pv2 \gset
select public.bulk_price_preview('percent', 2.5, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea')))) as r1 \gset
select public.bulk_price_preview('percent', 2.5, 0.5, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea')))) as r05 \gset
select public.bulk_price_preview('percent', 2.5, 0.01, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea')))) as r001 \gset
select public.bulk_price_preview('amount', -25, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('tea')))) as floor0 \gset
select public.bulk_price_preview('amount', 0.4, 0.5, jsonb_build_object('product_ids', jsonb_build_array(t.id('soup')))) as amt \gset
reset role;
select t.q('2.5 with outlet prices switched off only the 3 base lines appear', :'pv2'::jsonb -> 'total_lines', '3');
select t.q('2.6 rounding 1: Tea 20 + 2.5% = 20.5 -> 21', :'r1'::jsonb #> '{lines,0,new_price}', '21');
select t.q('2.7 rounding 0.5: 20.5 stays', :'r05'::jsonb #> '{lines,0,new_price}', '20.5');
select t.q('2.8 rounding 0.01: 20.50', :'r001'::jsonb #> '{lines,0,new_price}', '20.5');
select t.q('2.9 a price never goes below zero', :'floor0'::jsonb #> '{lines,0,new_price}', '0');
select t.q('2.10 amount +0.40 on Soup 80 with rounding 0.5 -> 80.5', :'amt'::jsonb #> '{lines,0,new_price}', '80.5');
select t.q('2.11 an outlet override that is null (Tea at Outlet A, only unavailable) is not a price line', :'r1'::jsonb -> 'total_lines', '1');
select t.as_('mgr');
select t.err('2.12 zero change refused', $q$ select public.bulk_price_preview('percent', 0, 1, '{"all":true}') $q$, 'how much');
select t.err('2.13 bad rounding refused', $q$ select public.bulk_price_preview('percent', 5, 2, '{"all":true}') $q$, 'Round to');
select t.err('2.14 empty scope refused', $q$ select public.bulk_price_preview('percent', 5, 1, '{}') $q$, 'Choose which dishes');
select t.err('2.15 -95% refused', $q$ select public.bulk_price_preview('percent', -95, 1, '{"all":true}') $q$, 'between -90 and 500');
select t.err('2.16 a reason is required to apply', $q$ select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('category_ids', jsonb_build_array(t.id('catFood'))), true, '  ') $q$, 'reason');
select t.err('2.17 the preview count is checked: a stale preview is refused', $q$ select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('category_ids', jsonb_build_array(t.id('catFood'))), true, 'Festival', null, 4) $q$, 'Preview again');
reset role;
select t.q('2.18 refused applies changed nothing', (select to_jsonb(count(*)) from public.price_change_batches), '0');

select count(*) as alerts_before from public.owner_alerts \gset
select t.as_('mgr');
select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('category_ids', jsonb_build_array(t.id('catFood'))), true, 'Festival rise', t.id('ref1'), 5) as ap \gset
reset role;
select t.same('2.19 apply returns the batch and 5 lines (same as the preview)', :'ap'::jsonb - 'batch_id', '{"total_lines":5,"base_lines":3,"branch_lines":2,"already_applied":false}');
select t.q('2.20 base prices moved: Burger 110, Pizza 330, Soup 88; others untouched (Tea 20, Coffee 100, other restaurant 100)',
  (select jsonb_object_agg(name || coalesce(restaurant_id::text, '')::text, price) from (select p.name, case when p.restaurant_id = t.id('rest2') then 'R2' else '' end as restaurant_id, p.price from public.products p) q),
  '{"Burger":110,"Pizza":330,"Soup":88,"Tea":20,"Coffee":100,"BurgerR2":100}');
select t.q('2.21 outlet prices moved: Burger@A 121, Pizza@B 352; the null Tea@A override is still null',
  (select to_jsonb(array_agg(coalesce(bp.price::text, 'null') order by p.name)) from public.branch_prices bp join public.products p on p.id = bp.product_id),
  '["121.00","352.00","null"]');
select t.q('2.22 the applied lines equal the preview lines (count, old and new prices)',
  (select jsonb_agg(jsonb_build_array(p.name, l.scope, l.old_price, l.new_price) order by p.name, l.scope) from public.price_change_lines l join public.products p on p.id = l.product_id),
  (select jsonb_agg(jsonb_build_array(e ->> 'name', e ->> 'scope', e -> 'old_price', e -> 'new_price') order by e ->> 'name', e ->> 'scope') from jsonb_array_elements(:'pv'::jsonb -> 'lines') e)::text);
select t.q('2.23 exactly ONE summary audit row and NO per-dish price audit row',
  jsonb_build_object('summary', (select count(*) from public.audit_logs where action = 'menu.bulk_price_change'),
                     'per_dish', (select count(*) from public.audit_logs where action = 'menu.price_or_tax_changed')), '{"summary":1,"per_dish":0}');
select t.q('2.24 the summary audit row has the batch id, count, reason',
  (select jsonb_build_object('batch', new_value ->> 'batch_id' = (:'ap'::jsonb ->> 'batch_id'), 'n', new_value -> 'prices_changed', 'reason', new_value ->> 'reason') from public.audit_logs where action = 'menu.bulk_price_change'),
  '{"batch":true,"n":5,"reason":"Festival rise"}');
select t.q('2.25 exactly ONE owner alert for the whole batch', (select to_jsonb(count(*)) from public.owner_alerts) , (:alerts_before + 1)::text);
select t.q('2.26 product_price_history still records each changed base price (3 new rows)', (select to_jsonb(count(*)) from public.product_price_history where price in (110, 330, 88) and valid_to is null), '3');
select t.q('2.27 the open bill keeps the price it was rung at (Burger 100)', (select to_jsonb(unit_price) from public.order_items where id = t.id('oi1')), '100');
select t.as_('mgr');
select public.bulk_price_apply('percent', 10, 1, jsonb_build_object('category_ids', jsonb_build_array(t.id('catFood'))), true, 'Festival rise', t.id('ref1'), 5) as ap2 \gset
reset role;
select t.same('2.28 the same client_ref again returns the first batch and changes nothing more',
  jsonb_build_object('same', (:'ap2'::jsonb ->> 'batch_id') = (:'ap'::jsonb ->> 'batch_id'), 'again', :'ap2'::jsonb -> 'already_applied', 'burger', (select price from public.products where id = t.id('burger')),
                     'batches', (select count(*) from public.price_change_batches)),
  '{"same":true,"again":true,"burger":110,"batches":1}');

-- someone edits Soup by hand afterwards, then the batch is undone
update public.products set price = 99 where id = t.id('soup');
select count(*) as alerts_before_undo from public.owner_alerts \gset
select t.as_('carl');
select t.err('2.29 a Cashier cannot undo', format($q$ select public.bulk_price_undo(%L) $q$, :'ap'::jsonb ->> 'batch_id'), '(menu.price_change)');
select t.as_('mgr');
select public.bulk_price_undo((:'ap'::jsonb ->> 'batch_id')::uuid, 'Customers complained') as un \gset
reset role;
select t.same('2.30 undo restores 4 lines and leaves the hand-edited Soup (99) alone', :'un'::jsonb - 'batch_id', '{"restored":4,"skipped":1}');
select t.q('2.31 prices after undo: Burger 100, Pizza 300, Soup 99, Burger@A 110, Pizza@B 320',
  jsonb_build_array((select price from public.products where id = t.id('burger')), (select price from public.products where id = t.id('pizza')), (select price from public.products where id = t.id('soup')),
    (select price from public.branch_prices where product_id = t.id('burger')), (select price from public.branch_prices where product_id = t.id('pizza'))), '[100,300,99,110,320]');
select t.q('2.32 batch marked undone, lines marked restored/skipped',
  jsonb_build_object('status', (select status from public.price_change_batches), 'restored', (select count(*) from public.price_change_lines where undo_state = 'restored'),
                     'skipped', (select count(*) from public.price_change_lines where undo_state = 'skipped')), '{"status":"undone","restored":4,"skipped":1}');
select t.q('2.33 one undo audit row, no per-dish rows from the undo (the earlier hand edit of Soup has its own), one more alert',
  jsonb_build_object('undo', (select count(*) from public.audit_logs where action = 'menu.bulk_price_undo'), 'per_dish', (select count(*) from public.audit_logs where action = 'menu.price_or_tax_changed' and entity_id <> t.id('soup')),
                     'alerts', (select count(*) from public.owner_alerts) - :alerts_before_undo), '{"undo":1,"per_dish":0,"alerts":1}');
select t.as_('mgr');
select t.err('2.34 a second undo is refused', format($q$ select public.bulk_price_undo(%L) $q$, :'ap'::jsonb ->> 'batch_id'), 'already undone');
select t.err('2.35 an unknown batch is not found', $q$ select public.bulk_price_undo(gen_random_uuid()) $q$, 'not found');
reset role;
select t.q('2.36 the open bill is still at 100', (select to_jsonb(unit_price) from public.order_items where id = t.id('oi1')), '100');

-- a Steward with a manager PIN approval may apply (the approval is consumed)
insert into public.approvals (restaurant_id, requested_by, approved_by, permission_key) values (t.id('rest1'), t.id('stan'), t.id('mgr'), 'menu.price_change');
select t.as_('stan');
select public.bulk_price_apply('amount', 1, 1, jsonb_build_object('product_ids', jsonb_build_array(t.id('coffee'))), true, 'Milk cost up') as pin \gset
reset role;
select t.q('2.37 with a manager PIN approval a person without the right can apply: Coffee 101, approval used',
  jsonb_build_array((select price from public.products where id = t.id('coffee')), (select used_at is not null from public.approvals where requested_by = t.id('stan') and permission_key = 'menu.price_change')), '[101,true]');
select t.as_('stan');
select t.err('2.38 without a new approval the Steward is refused again', $q$ select public.bulk_price_apply('amount', 1, 1, '{"product_ids":[]}'::jsonb || jsonb_build_object('product_ids', jsonb_build_array(t.id('coffee'))), true, 'again') $q$, '(menu.price_change)');
reset role;
-- the normal single-price guard still audits per dish and still refuses people without the right
select t.as_('mgr');
select t.err('2.39 a person without the right still cannot change one price directly (guard intact)', 
  format($q$ set local role authenticated; select set_config('request.jwt.claim.sub', %L, true); update public.products set price = 50 where id = %L $q$, t.id('auth:nina')::text, t.id('tea')::text), '');
reset role;
select t.q('2.40 Tea untouched by that attempt', (select to_jsonb(price) from public.products where id = t.id('tea')), '20');
select t.as_('mgr');
update public.products set price = 21 where id = t.id('tea');
reset role;
select t.q('2.41 one direct price edit by a person with the right still writes its own per-dish audit row',
  (select to_jsonb(count(*)) from public.audit_logs where action = 'menu.price_or_tax_changed' and entity_id = t.id('tea')), '1');
select t.as_('carl');
select t.q('2.42 a Cashier cannot read the batch tables', (select to_jsonb((select count(*) from public.price_change_batches) + (select count(*) from public.price_change_lines))), '0');
select t.err('2.43 a signed-in person cannot write the batch table directly', $q$ insert into public.price_change_batches (restaurant_id, mode, value, rounding, reason) values (t.id('rest1'), 'percent', 1, 1, 'xxx') $q$, 'permission denied');
select t.as_('mgr');
select t.q('2.44 a Manager reads the batches of the restaurant (2: undone festival + coffee)', (select to_jsonb(count(*)) from public.price_change_batches), '2');
select public.bulk_price_history(10) as hist \gset
reset role;
select t.q('2.44b history lists the two batches newest first with who, status, line counts',
  (select jsonb_agg(jsonb_build_array(e ->> 'status', e -> 'lines', e ->> 'by', e ->> 'reason', e ->> 'undone_by')) from jsonb_array_elements(:'hist'::jsonb) e),
  '[["applied",1,"Stan Steward","Milk cost up",null],["undone",5,"Maya Manager","Festival rise","Maya Manager"]]');
select t.as_('carl');
select t.err('2.44c a Cashier cannot read the history', $q$ select public.bulk_price_history() $q$, '(menu.price_change)');
select t.as_('other');
select t.q('2.45 another restaurant sees no batches', (select to_jsonb(count(*)) from public.price_change_batches), '0');
reset role;

-- ================================================================ 137 copy rights and access
select t.as_('mgr');
select t.err('3.1 a non-owner (even with user.manage) cannot copy rights', $q$ select public.copy_role_rights(t.id('roleTemplate'), t.id('roleCustom'), 'add') $q$, 'Only an owner');
select t.as_('carl');
select t.err('3.2 a person without user.manage cannot', $q$ select public.copy_role_rights(t.id('roleTemplate'), t.id('roleCustom'), 'add') $q$, '(user.manage)');
select t.as_('owner');
select t.err('3.3 the Owner role is never a target', $q$ select public.copy_role_rights(t.id('roleTemplate'), t.id('roleOwner'), 'replace') $q$, 'cannot be changed');
select t.err('3.4 a role cannot copy from itself', $q$ select public.copy_role_rights(t.id('roleCustom'), t.id('roleCustom'), 'add') $q$, 'different role');
select t.err('3.5 a role of another restaurant is not found', $q$ select public.copy_role_rights(t.id('roleOther2'), t.id('roleCustom'), 'add') $q$, 'not found');
select t.err('3.6 an unknown mode is refused', $q$ select public.copy_role_rights(t.id('roleTemplate'), t.id('roleCustom'), 'merge') $q$, 'add or replace');
select public.copy_role_rights(t.id('roleTemplate'), t.id('roleCustom'), 'add') as c1 \gset
reset role;
select t.same('3.7 add: Custom {order.create, shift.open} + Template {order.create, order.discount, payment.take}', :'c1'::jsonb - 'role_id',
  '{"mode":"add","added":["order.discount","payment.take"],"removed":[],"total":4}');
select t.q('3.8 Custom now has the union', (select to_jsonb(array_agg(permission_key order by permission_key)) from public.role_permissions where role_id = t.id('roleCustom')),
  '["order.create","order.discount","payment.take","shift.open"]');
select t.as_('owner');
select public.copy_role_rights(t.id('roleTemplate'), t.id('roleCustom'), 'replace') as c2 \gset
reset role;
select t.same('3.9 replace: Custom becomes exactly Template; shift.open removed', :'c2'::jsonb - 'role_id', '{"mode":"replace","added":[],"removed":["shift.open"],"total":3}');
select t.q('3.10 Custom equals Template', (select to_jsonb(array_agg(permission_key order by permission_key)) from public.role_permissions where role_id = t.id('roleCustom')),
  '["order.create","order.discount","payment.take"]');
select t.q('3.11 the source role is unchanged', (select to_jsonb(count(*)) from public.role_permissions where role_id = t.id('roleTemplate')), '3');
select t.q('3.12 audit role.rights_copied: two rows, naming the source and the changes',
  (select jsonb_agg(jsonb_build_array(new_value ->> 'from_role', new_value ->> 'mode', new_value -> 'added', new_value -> 'removed') order by id) from public.audit_logs where action = 'role.rights_copied'),
  '[["Template","add",["order.discount","payment.take"],[]],["Template","replace",[],["shift.open"]]]');
select t.q('3.13 the Owner role keeps its rights', (select to_jsonb(count(*)) from public.role_permissions where role_id = t.id('roleOwner')), '5');

-- staff access
select t.as_('carl');
select t.err('3.14 a person without user.manage cannot copy access', $q$ select public.copy_staff_access(t.id('carl'), t.id('stan')) $q$, '(user.manage)');
select t.as_('mgr');
select public.copy_staff_access(t.id('carl'), t.id('stan')) as a1 \gset
reset role;
select t.same('3.15 Stan gets Carl''s role (Cashier) and outlet (A only)', :'a1'::jsonb - 'user_id', jsonb_build_object('role', 'Cashier', 'outlets', jsonb_build_array(t.id('outA')), 'all_outlets', false)::text);
select t.q('3.16 stored: role Cashier, one outlet row',
  jsonb_build_array((select r.name from public.users u join public.roles r on r.id = u.role_id where u.id = t.id('stan')), (select count(*) from public.user_branches where user_id = t.id('stan'))), '["Cashier",1]');
select t.as_('mgr');
select public.copy_staff_access(t.id('nina'), t.id('stan')) as a2 \gset
reset role;
select t.same('3.17 copying from a person with no outlet limit (Nina: all outlets) clears Stan''s outlet limit', :'a2'::jsonb - 'user_id',
  jsonb_build_object('role', 'Nobody', 'outlets', jsonb_build_array(), 'all_outlets', true)::text);
select t.q('3.18 Stan: role Nobody, no outlet rows', jsonb_build_array((select r.name from public.users u join public.roles r on r.id = u.role_id where u.id = t.id('stan')), (select count(*) from public.user_branches where user_id = t.id('stan'))), '["Nobody",0]');
select t.q('3.19 two audit rows user.access_copied with before and after role',
  (select jsonb_agg(jsonb_build_array(new_value ->> 'role', old_value ->> 'role', new_value ->> 'from_user') order by id) from public.audit_logs where action = 'user.access_copied'),
  '[["Cashier","Steward","Carl Cashier"],["Nobody","Cashier","Nina Nobody"]]');
select t.as_('mgr');
select t.err('3.20 you cannot change your own access', $q$ select public.copy_staff_access(t.id('carl'), t.id('mgr')) $q$, 'your own');
select t.err('3.21 access is not copied onto an owner', $q$ select public.copy_staff_access(t.id('carl'), t.id('owner')) $q$, 'onto an owner');
select t.err('3.22 access is not copied from an owner', $q$ select public.copy_staff_access(t.id('owner'), t.id('wes')) $q$, 'from an owner');
select t.err('3.23 a person of another restaurant is not found', $q$ select public.copy_staff_access(t.id('other'), t.id('wes')) $q$, 'not found');
select t.err('3.24 copying from yourself is refused', $q$ select public.copy_staff_access(t.id('wes'), t.id('wes')) $q$, 'different person');
reset role;

-- ---------------------------------------------------------------- result
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
select case when :failed > 0 then 1/0 end as stop_if_failed;
