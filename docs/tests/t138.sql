-- t138.sql: proves migration 138 (report_covers, report_reprints, report_tips, fixed report_pending_kot / report_pending_bills)
-- on a database with migrations 001..129 applied + a STAND-IN order_tips table (see the marked block below).
-- Run as a superuser (it creates its own fixtures and impersonates users with SET ROLE authenticated + JWT claims).
-- Run it on a FRESH scratch database (docs/tests/run-t138.sh builds one). Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
set session_replication_role = replica;      -- fixtures are written straight into the tables (no billing triggers); the RPCs under test are read-only
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
grant usage on schema t to public; grant all on t.res to public; grant usage on sequence t.res_n_seq to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t138:' || p)::uuid $$;
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
create function t.mk_order(k text, p_branch text, p_date date, p_status text, p_comp text, p_cashier text, p_waiter text, p_covers int,
                           p_sub numeric, p_disc numeric, p_svc numeric, p_tax numeric, p_round numeric, p_grand numeric, p_pay text,
                           p_merged text default null, p_table text default null, p_rest text default 'rest1', p_created timestamptz default null,
                           p_void_reason text default 'test void', p_voided_by text default 'owner') returns void language plpgsql as $$
begin
  insert into public.orders (id, restaurant_id, branch_id, bill_number, order_type, dining_table_id, cashier_id, waiter_id, currency_code, client_created_at, created_at,
                             business_date, status, payment_status, comp_kind, comp_reason, comp_by, covers, subtotal, discount_total, service_charge, tax_total,
                             rounding_adjustment, grand_total, merged_into, voided_by, void_reason, voided_at)
  values (t.id(k), t.id(p_rest), t.id(p_branch), upper(k), case when p_table is null then 'takeaway' else 'dine_in' end,
          case when p_table is null then null else t.id(p_table) end, t.id(p_cashier), case when p_waiter is null then null else t.id(p_waiter) end, 'INR',
          coalesce(p_created, p_date::timestamptz + interval '8 hours'), coalesce(p_created, p_date::timestamptz + interval '8 hours'),
          p_date, p_status, p_pay, p_comp, case when p_comp is null then null else 'test reason' end, case when p_comp is null then null else t.id('owner') end,
          p_covers, p_sub, p_disc, p_svc, p_tax, p_round, p_grand,
          case when p_merged is null then null else t.id(p_merged) end,
          case when p_status = 'voided' then t.id(p_voided_by) end, case when p_status = 'voided' then p_void_reason end,
          case when p_status = 'voided' then p_date::timestamptz + interval '9 hours' end);
end $$;
create function t.mk_item(k text, p_order text, p_prod text, p_name text, p_qty numeric, p_unit numeric, p_net numeric default 0, p_cancelled boolean default false, p_rest text default 'rest1') returns void language plpgsql as $$
begin
  insert into public.order_items (id, restaurant_id, order_id, product_id, product_name, unit_price, quantity, line_subtotal, line_total, net_amount, cancelled_at)
  values (t.id(k), t.id(p_rest), t.id(p_order), t.id(p_prod), p_name, p_unit, p_qty, p_qty * p_unit, p_qty * p_unit, p_net, case when p_cancelled then now() end);
end $$;
create function t.mk_pay(k text, p_order text, p_pm text, p_amt numeric, p_status text default 'captured', p_round numeric default 0, p_rest text default 'rest1') returns void language plpgsql as $$
declare d timestamptz;
begin
  select o.created_at + interval '30 minutes' into d from public.orders o where o.id = t.id(p_order);
  insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, received_by, client_created_at, created_at, status, rounding_adjustment, reference_no)
  values (t.id(k), t.id(p_rest), t.id(p_order), t.id(p_pm), p_amt, 'INR', t.id('owner'), d, d, p_status, p_round, 'ref-' || k);
end $$;
create function t.mk_kot(k text, p_order text, p_status text, p_created timestamptz, p_branch text, p_rest text default 'rest1') returns void language sql as $$
  insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, station, status, client_created_at, created_at)
  values (t.id(k), t.id(p_rest), t.id(p_branch), t.id(p_order), 'K-' || upper(k), 'Kitchen', p_status, p_created, p_created) $$;
create function t.mk_kitem(k text, p_kot text, p_item text, p_name text, p_qty numeric, p_status text, p_rest text default 'rest1') returns void language sql as $$
  insert into public.kitchen_ticket_items (id, restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, status)
  values (t.id(k), t.id(p_rest), t.id(p_kot), t.id(p_item), p_name, p_qty, p_status) $$;
create function t.pick(j jsonb, ks text[]) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg((select jsonb_agg(e -> k order by ord) from unnest(ks) with ordinality as u(k, ord))), '[]'::jsonb) from jsonb_array_elements(j) e $$;
create function t.sr(p_sr jsonb, p_path text[]) returns jsonb language sql immutable as $$ select p_sr #> p_path $$;

-- ---------------------------------------------------------------- fixtures
do $$
declare r1 uuid := t.id('rest1'); r2 uuid := t.id('rest2'); a uuid := t.id('outA'); b uuid := t.id('outB'); c uuid := t.id('outC'); cat uuid := t.id('cat1'); x text;
begin
  insert into public.restaurants (id, legal_name, trading_name, country_code, currency_code, timezone, edition)
    values (r1, 'Test One Pvt Ltd', 'Test One', 'IN', 'INR', 'Asia/Kolkata', 'professional'), (r2, 'Test Two Pvt Ltd', 'Test Two', 'IN', 'INR', 'Asia/Kolkata', 'professional');
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone)
    values (a, r1, 'Outlet A', 'A', 'IN', 'Asia/Kolkata'), (b, r1, 'Outlet B', 'B', 'IN', 'Asia/Kolkata'), (c, r2, 'Outlet C', 'C', 'IN', 'Asia/Kolkata');
  insert into public.tax_groups (id, restaurant_id, name) values (t.id('tax1'), r1, 'GST'), (t.id('tax2'), r2, 'GST');
  insert into public.categories (id, restaurant_id, name) values (cat, r1, 'Food'), (t.id('cat2'), r2, 'Food');
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values
    (t.id('burger'), r1, cat, t.id('tax1'), 'Burger', 100), (t.id('tea'), r1, cat, t.id('tax1'), 'Tea', 20);
  insert into public.roles (id, restaurant_id, name, is_system) values
    (t.id('roleOwner'), r1, 'Owner', true), (t.id('roleCashier'), r1, 'Cashier', false), (t.id('roleNobody'), r1, 'Nobody', false), (t.id('roleOwner2'), r2, 'Owner', true);
  insert into public.role_permissions (role_id, permission_key) values
    (t.id('roleOwner'), 'report.view_sales'), (t.id('roleOwner'), 'report.view_financial'),
    (t.id('roleCashier'), 'report.view_sales'),
    (t.id('roleOwner2'), 'report.view_sales'), (t.id('roleOwner2'), 'report.view_financial');
  foreach x in array array['owner','carl','nina','wendy','wes','other'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t138.test');
  end loop;
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values
    (t.id('owner'), r1, t.id('auth:owner'), 'E1', 'Olivia Owner', t.id('roleOwner'),   'owner@t138.test'),
    (t.id('carl'),  r1, t.id('auth:carl'),  'E2', 'Carl Cashier', t.id('roleCashier'), 'carl@t138.test'),
    (t.id('nina'),  r1, t.id('auth:nina'),  'E4', 'Nina Nobody',  t.id('roleNobody'),  'nina@t138.test'),
    (t.id('wendy'), r1, t.id('auth:wendy'), 'E5', 'Wendy Waiter', t.id('roleCashier'), 'wendy@t138.test'),
    (t.id('wes'),   r1, t.id('auth:wes'),   'E6', 'Wes Waiter',   t.id('roleCashier'), 'wes@t138.test'),
    (t.id('other'), r2, t.id('auth:other'), 'E7', 'Other Owner',  t.id('roleOwner2'),  'other@t138.test');
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (t.id('carl'), a, r1);
  insert into public.payment_methods (id, restaurant_id, name, kind) values
    (t.id('pmCash'), r1, 'Cash', 'cash'), (t.id('pmCard'), r1, 'Card', 'card'), (t.id('pmCash2'), r2, 'Cash', 'cash');
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number) values
    (t.id('T1'), r1, a, 'T1'), (t.id('T2'), r1, a, 'T2'), (t.id('TB1'), r1, b, 'B1'), (t.id('TC1'), r2, c, 'C1');
end $$;

-- ===== STAND-IN, NOT PART OF THIS CHANGE =====================================================================================
-- order_tips is created by migration 133 (another workstream). This minimal copy has the same columns so that report_tips can be
-- tested here without that branch. Remove this block when the real 133 is replayed first (the script then skips it).
do $$ begin
  if to_regclass('public.order_tips') is null then
    create table public.order_tips (
      id uuid primary key default gen_random_uuid(), restaurant_id uuid not null, branch_id uuid not null, order_id uuid not null,
      payment_id uuid, method_id uuid, amount numeric(14,2) not null check (amount > 0), waiter_id uuid, received_by uuid, shift_id uuid,
      business_date date not null, created_at timestamptz not null default now());
    raise notice 'STAND-IN order_tips created';
  end if;
end $$;
-- ===== END STAND-IN ==========================================================================================================

\set F '\'2026-10-19\'::date, \'2026-10-21\'::date'
\set FP '\'2026-10-17\'::date, \'2026-10-17\'::date'

-- ---------------------------------------------------------------- orders: covers fixtures
select t.mk_order('c1',  'outA', '2026-10-20', 'completed', null, 'carl', 'wendy', 2, 500, 0, 0, 0, 0, 500, 'paid', null, 'T1');
select t.mk_order('c2',  'outA', '2026-10-20', 'completed', null, 'carl', 'wendy', 4, 700, 0, 0, 0, 0, 700, 'paid', null, 'T1');
select t.mk_order('c3',  'outA', '2026-10-21', 'completed', null, 'carl', null,    null, 300, 0, 0, 0, 0, 300, 'paid', null, 'T2');   -- dine-in without covers; cashier counts as waiter
select t.mk_order('c4',  'outA', '2026-10-20', 'completed', null, 'carl', 'wendy', 3, 111, 0, 0, 0, 0, 111, 'paid');               -- takeaway: left out
select t.mk_order('c5',  'outA', '2026-10-20', 'voided',    null, 'carl', 'wendy', 5, 222, 0, 0, 0, 0, 222, 'unpaid', null, 'T1');   -- voided: left out
select t.mk_order('c6',  'outA', '2026-10-20', 'completed', null, 'carl', 'wendy', 6, 333, 0, 0, 0, 0, 333, 'paid', 'c1', 'T1');   -- merged: left out
select t.mk_order('c7',  'outB', '2026-10-21', 'completed', null, 'owner','wes',   3, 450, 0, 0, 0, 0, 450, 'paid', null, 'TB1');
select t.mk_order('c8',  'outC', '2026-10-20', 'completed', null, 'other','other', 9, 999, 0, 0, 0, 0, 999, 'paid', null, 'TC1', 'rest2'); -- other restaurant
select t.mk_order('c9',  'outA', '2026-10-18', 'completed', null, 'carl', 'wendy', 7, 777, 0, 0, 0, 0, 777, 'paid', null, 'T1');   -- before the range
select t.mk_order('c10', 'outA', '2026-10-21', 'completed', 'complimentary', 'carl', 'wendy', 2, 200, 200, 0, 0, 0, 0, 'paid', null, 'T2'); -- complimentary: counts guests, 0 sales

-- ---------------------------------------------------------------- orders / kitchen: pending KOT + pending bills fixtures (business day 2026-10-17, outside the covers range)
-- k1: bill completed + unpaid (what create_order really makes), ticket row made 3 h ago but client time 30 min ago -> shown, pending ~30 min
select t.mk_order('p1', 'outA', '2026-10-17', 'completed', null, 'carl', 'wendy', 2, 400, 0, 0, 0, 0, 400, 'unpaid', null, 'T1', 'rest1', now() - interval '3 hours');
select t.mk_item('pi1', 'p1', 'burger', 'Burger', 1, 100, 100);
select t.mk_kot('k1', 'p1', 'new', now() - interval '3 hours', 'outA');
update public.kitchen_tickets set client_created_at = now() - interval '30 minutes' where id = t.id('k1');
select t.mk_kitem('ki1', 'k1', 'pi1', 'Burger', 1, 'new');
-- k2: completed + PAID takeaway, food still cooking -> shown
select t.mk_order('p2', 'outA', '2026-10-17', 'completed', null, 'carl', null, null, 120, 0, 0, 0, 0, 120, 'paid');
select t.mk_item('pi2', 'p2', 'tea', 'Tea', 2, 20, 40);
select t.mk_kot('k2', 'p2', 'preparing', now() - interval '20 minutes', 'outA'); select t.mk_kitem('ki2', 'k2', 'pi2', 'Tea', 2, 'preparing');
-- k3 voided bill -> not shown; k4 merged bill -> not shown; k5 ready item -> not shown; k6 other outlet B -> shown to owner/all only
select t.mk_order('p3', 'outA', '2026-10-17', 'voided', null, 'carl', null, null, 50, 0, 0, 0, 0, 50, 'unpaid', null, 'T2');
select t.mk_item('pi3', 'p3', 'tea', 'Tea', 1, 20, 20); select t.mk_kot('k3', 'p3', 'new', now() - interval '1 hour', 'outA'); select t.mk_kitem('ki3', 'k3', 'pi3', 'Tea', 1, 'new');
select t.mk_order('p4', 'outA', '2026-10-17', 'completed', null, 'carl', null, null, 60, 0, 0, 0, 0, 60, 'unpaid', 'p1', 'T1');
select t.mk_item('pi4', 'p4', 'tea', 'Tea', 3, 20, 60); select t.mk_kot('k4', 'p4', 'new', now() - interval '1 hour', 'outA'); select t.mk_kitem('ki4', 'k4', 'pi4', 'Tea', 3, 'new');
select t.mk_order('p5', 'outA', '2026-10-17', 'completed', null, 'carl', null, null, 20, 0, 0, 0, 0, 20, 'paid');
select t.mk_item('pi5', 'p5', 'tea', 'Tea', 1, 20, 20); select t.mk_kot('k5', 'p5', 'ready', now() - interval '1 hour', 'outA'); select t.mk_kitem('ki5', 'k5', 'pi5', 'Tea', 1, 'ready');
select t.mk_order('p6', 'outB', '2026-10-17', 'completed', null, 'owner', 'wes', 1, 80, 0, 0, 0, 0, 80, 'unpaid', null, 'TB1');
select t.mk_item('pi6', 'p6', 'tea', 'Tea', 4, 20, 80); select t.mk_kot('k6', 'p6', 'new', now() - interval '10 minutes', 'outB'); select t.mk_kitem('ki6', 'k6', 'pi6', 'Tea', 4, 'new');
-- pending bills: p1 (dine, unpaid, completed) -> open; d2 dine partial (paid 200 of 600) -> open, balance 400; d3 takeaway unpaid -> unsettled;
-- d4 dine paid -> absent; d5 legacy status 'open' dine unpaid -> open
select t.mk_order('d2', 'outA', '2026-10-17', 'completed', null, 'carl', 'wendy', 2, 600, 0, 0, 0, 0, 600, 'partial', null, 'T2'); select t.mk_pay('dp2', 'd2', 'pmCash', 200);
select t.mk_order('d3', 'outA', '2026-10-17', 'completed', null, 'carl', null, null, 150, 0, 0, 0, 0, 150, 'unpaid');
select t.mk_order('d4', 'outA', '2026-10-17', 'completed', null, 'carl', 'wendy', 2, 700, 0, 0, 0, 0, 700, 'paid', null, 'T1'); select t.mk_pay('dp4', 'd4', 'pmCash', 700);
select t.mk_order('d5', 'outA', '2026-10-17', 'open', null, 'carl', 'wendy', 2, 90, 0, 0, 0, 0, 90, 'unpaid', null, 'T2');

-- ---------------------------------------------------------------- audit rows for reprints (restaurant time zone Asia/Kolkata = UTC+5:30)
insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, new_value, created_at) values
  (t.id('rest1'), t.id('outA'), t.id('carl'),  'bill.reprint', 'orders', t.id('c1'), '{"kind":"bill","reprint_no":1}', '2026-10-20 06:00:00+00'),
  (t.id('rest1'), t.id('outA'), t.id('carl'),  'kot.reprint',  'orders', t.id('c2'), '{"kind":"kot","ticket_ids":["x","y"]}', '2026-10-20 07:00:00+00'),
  (t.id('rest1'), t.id('outA'), t.id('wendy'), 'bill.reprint', 'orders', t.id('c2'), '{"kind":"bill","reprint_no":1}', '2026-10-20 08:00:00+00'),
  (t.id('rest1'), t.id('outA'), t.id('carl'),  'bill.reprint', 'orders', t.id('c3'), '{"kind":"bill","reprint_no":2}', '2026-10-20 19:00:00+00'),  -- 21 Oct 00:30 in Kolkata
  (t.id('rest1'), t.id('outA'), t.id('carl'),  'bill.print',   'orders', t.id('c3'), '{"kind":"bill"}', '2026-10-20 09:00:00+00'),               -- first print: not a reprint
  (t.id('rest1'), t.id('outB'), t.id('wes'),   'kot.reprint',  'orders', t.id('c7'), '{"kind":"kot"}', '2026-10-21 05:00:00+00'),
  (t.id('rest1'), t.id('outA'), t.id('carl'),  'bill.reprint', 'orders', t.id('c9'), '{}', '2026-10-18 05:00:00+00'),                              -- before the range
  (t.id('rest1'), t.id('outA'), t.id('carl'),  'bill.reprint', 'orders', t.id('c1'), '{}', '2026-10-21 18:30:00+00'),                              -- 22 Oct 00:00 in Kolkata: after the range
  (t.id('rest2'), t.id('outC'), t.id('other'), 'bill.reprint', 'orders', t.id('c8'), '{}', '2026-10-20 06:00:00+00');                              -- other restaurant

-- ---------------------------------------------------------------- tips (stand-in table; real columns)
insert into public.order_tips (restaurant_id, branch_id, order_id, method_id, amount, waiter_id, received_by, business_date) values
  (t.id('rest1'), t.id('outA'), t.id('c1'),  t.id('pmCash'), 50, t.id('wendy'), t.id('carl'), '2026-10-20'),
  (t.id('rest1'), t.id('outA'), t.id('c2'),  t.id('pmCard'), 30, null,          t.id('carl'), '2026-10-20'),   -- no waiter: received_by counts
  (t.id('rest1'), t.id('outA'), t.id('c3'),  t.id('pmCash'), 20, t.id('wendy'), t.id('carl'), '2026-10-21'),
  (t.id('rest1'), t.id('outA'), t.id('c5'),  t.id('pmCash'), 99, t.id('wendy'), t.id('carl'), '2026-10-20'),   -- tip on a VOIDED bill: left out
  (t.id('rest1'), t.id('outB'), t.id('c7'),  t.id('pmCard'), 40, t.id('wes'),   t.id('owner'),'2026-10-21'),
  (t.id('rest1'), t.id('outA'), t.id('c9'),  t.id('pmCash'), 77, t.id('wendy'), t.id('carl'), '2026-10-18'),   -- before the range
  (t.id('rest2'), t.id('outC'), t.id('c8'),  t.id('pmCash2'),66, t.id('other'), t.id('other'),'2026-10-20');   -- other restaurant

update public.users set all_outlets = true, current_branch_id = t.id('outA') where id = t.id('owner');

-- ================================================================ 1. COVERS
select t.as_('owner');
select public.report_covers(:F) as cv \gset
reset role;
select t.same('1.1 covers totals: dine-in completed non-merged bills c1 c2 c3 c7 c10 (takeaway, voided, merged, other day, other restaurant left out)',
  :'cv'::jsonb -> 'totals', '{"bills":5,"bills_with_covers":4,"bills_without_covers":1,"covers":11,"sales":1650,"sales_per_cover":150}');
select t.same('1.2 covers by day (sales = bills that have covers only)', t.pick(:'cv'::jsonb -> 'by_day', array['business_date','bills','covers','sales','sales_per_cover']),
  '[["2026-10-20",2,6,1200,200],["2026-10-21",3,5,450,90]]');
select t.same('1.3 covers by outlet (All outlets)', t.pick(:'cv'::jsonb -> 'by_outlet', array['outlet_name','bills','covers','sales','sales_per_cover']),
  '[["Outlet A",4,8,1200,150],["Outlet B",1,3,450,150]]');
select t.same('1.4 covers by waiter: waiter or else cashier (Carl has c3 without covers); most guests first',
  t.pick(:'cv'::jsonb -> 'by_waiter', array['staff_name','outlet_name','bills','covers','sales','sales_per_cover']),
  '[["Wendy Waiter","Outlet A",3,8,1200,150],["Wes Waiter","Outlet B",1,3,450,150],["Carl Cashier","Outlet A",1,0,0,null]]');
select t.same('1.5 money flag true for the owner', :'cv'::jsonb -> 'money', 'true');

-- Carl: sales right only, restricted to outlet A (user_branches). Money is hidden, not refused.
update public.users set all_outlets = true, current_branch_id = t.id('outB') where id = t.id('carl');   -- forced flags: a restricted person must still see A only
select t.as_('carl');
select public.report_covers(:F) as cv2 \gset
reset role;
select t.same('1.6 Carl (restricted to A, no financial right): outlet A only, money false, sales and sales per cover null, guests still shown',
  jsonb_build_object('money', :'cv2'::jsonb -> 'money', 'outlets', t.names(:'cv2'::jsonb -> 'by_outlet', 'outlet_name'),
                     'totals', :'cv2'::jsonb -> 'totals', 'day', t.pick(:'cv2'::jsonb -> 'by_day', array['business_date','covers','sales'])),
  '{"money":false,"outlets":["Outlet A"],"totals":{"bills":4,"bills_with_covers":3,"bills_without_covers":1,"covers":8,"sales":null,"sales_per_cover":null},"day":[["2026-10-20",6,null],["2026-10-21",2,null]]}');
update public.users set all_outlets = false, current_branch_id = null where id = t.id('carl');

-- ================================================================ 2. PENDING KOT (fixed)
select t.as_('owner');
select public.report_pending_kot(:FP) as kot, public.report_pending_bills(:FP) as pb \gset
reset role;
select t.same('2.1 pending KOT: k1 (completed+unpaid), k2 (completed+paid), k6 (outlet B); not voided k3, merged k4, ready k5. Ordered by KOT time',
  t.pick(:'kot'::jsonb -> 'rows', array['ticket_number','bill_number','order_status','outlet_name']),
  '[["K-K1","P1","completed","Outlet A"],["K-K2","P2","completed","Outlet A"],["K-K6","P6","completed","Outlet B"]]');
select t.same('2.2 pending KOT totals and shape keys unchanged', jsonb_build_object('t', :'kot'::jsonb -> 'totals', 'keys', (select jsonb_agg(k order by k collate "C") from jsonb_object_keys(:'kot'::jsonb -> 'rows' -> 0) k)),
  '{"t":{"kots":3,"items":3},"keys":["bill_number","branch_id","items","kitchen_ticket_id","kot_time","minutes_pending","order_id","order_status","order_type","outlet_name","station","table_number","ticket_number","ticket_status"]}');
select t.eq('2.3 pending KOT time = client_created_at (30 min), not the row time (3 h): k1 minutes_pending 30..31, k2 20..21',
  jsonb_build_array((:'kot'::jsonb -> 'rows' -> 0 ->> 'minutes_pending')::int between 30 and 31, (:'kot'::jsonb -> 'rows' -> 1 ->> 'minutes_pending')::int between 20 and 21), '[true,true]');
select t.same('2.4 pending KOT oldest first by the client time: k1 (30 min), k2 (20 min), k6 (10 min)', t.names(:'kot'::jsonb -> 'rows', 'ticket_number'), '["K-K1","K-K2","K-K6"]');

-- ================================================================ 3. PENDING BILLS (fixed)
select t.same('3.1 pending bills: unpaid dine-in bills are OPEN (p1 400, d2 600 paid 200, d5 legacy open 90; p6 in B 80); takeaway d3 stays unsettled; not paid d4, voided p3, merged p4, paid/other',
  t.pick((select jsonb_agg(r order by r ->> 'bill_number') from jsonb_array_elements(:'pb'::jsonb -> 'rows') r), array['bill_number','kind','amount','paid','balance','outlet_name']),
  '[["D2","open",600,200,400,"Outlet A"],["D3","unsettled",150,0,150,"Outlet A"],["D5","open",90,0,90,"Outlet A"],["P1","open",400,0,400,"Outlet A"],["P6","open",80,0,80,"Outlet B"]]');
select t.same('3.2 pending bills totals', :'pb'::jsonb -> 'totals', '{"bills":5,"amount":1320,"paid":200,"balance":1120}');
select t.same('3.3 pending bills shape keys unchanged', (select jsonb_agg(k order by k collate "C") from jsonb_object_keys(:'pb'::jsonb -> 'rows' -> 0) k),
  '["age_minutes","amount","balance","bill_number","branch_id","business_date","cashier","created_at","kind","order_id","order_status","order_type","outlet_name","paid","payment_status","table_number","waiter"]');

-- ================================================================ 4. REPRINTS
select t.as_('owner');
select public.report_reprints(:F) as rp \gset
reset role;
select t.same('4.1 reprints (All outlets, Kolkata days): newest first; bill.print, before/after range and other restaurant left out; the 00:30 row counts for 21 Oct',
  t.pick(:'rp'::jsonb -> 'rows', array['kind','user_name','bill_number','table_number','outlet_name']),
  '[["kot","Wes Waiter","C7","B1","Outlet B"],["bill","Carl Cashier","C3","T2","Outlet A"],["bill","Wendy Waiter","C2","T1","Outlet A"],["kot","Carl Cashier","C2","T1","Outlet A"],["bill","Carl Cashier","C1","T1","Outlet A"]]');
select t.same('4.2 reprints totals and by user', jsonb_build_object('t', :'rp'::jsonb -> 'totals', 'u', t.pick(:'rp'::jsonb -> 'by_user', array['user_name','bills','kots']), 'tr', :'rp'::jsonb -> 'truncated', 'n', :'rp'::jsonb -> 'total_rows'),
  '{"t":{"reprints":5,"bills":3,"kots":2},"u":[["Carl Cashier",2,1],["Wendy Waiter",1,0],["Wes Waiter",0,1]],"tr":false,"n":5}');
select t.same('4.3 reprint detail passes the audit new_value through', :'rp'::jsonb -> 'rows' -> 3 -> 'detail', '{"kind":"kot","ticket_ids":["x","y"]}');
select t.as_('carl');
select public.report_reprints(:F) as rp2 \gset
reset role;
select t.same('4.4 reprints, Carl (restricted to A): outlet A rows only', jsonb_build_object('n', :'rp2'::jsonb #> '{totals,reprints}', 'o', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'rp2'::jsonb -> 'rows') e)),
  '{"n":4,"o":["Outlet A"]}');

-- ================================================================ 5. TIPS
select t.as_('owner');
select public.report_tips(:F) as tp \gset
reset role;
select t.same('5.1 tips totals: 50+30+20+40 = 140 over 4 tips on 4 bills (voided c5 tip 99, before-range 77 and other restaurant 66 left out)', :'tp'::jsonb -> 'totals', '{"tips":4,"amount":140,"bills":4}');
select t.same('5.2 tips by day', t.pick(:'tp'::jsonb -> 'by_day', array['business_date','tips','amount']), '[["2026-10-20",2,80],["2026-10-21",2,60]]');
select t.same('5.3 tips by payment mode (biggest first)', t.pick(:'tp'::jsonb -> 'by_method', array['method','kind','tips','amount']), '[["Card","card",2,70],["Cash","cash",2,70]]');
select t.same('5.4 tips by waiter: waiter, else the person who received it (Carl got the 30 with no waiter)',
  t.pick(:'tp'::jsonb -> 'by_waiter', array['staff_name','outlet_name','tips','amount']),
  '[["Wendy Waiter","Outlet A",2,70],["Wes Waiter","Outlet B",1,40],["Carl Cashier","Outlet A",1,30]]');
select t.same('5.5 tips by outlet', t.pick(:'tp'::jsonb -> 'by_outlet', array['outlet_name','tips','amount']), '[["Outlet A",3,100],["Outlet B",1,40]]');
select t.as_('carl');
select t.err('5.6 Carl (sales only) refused the tips report', format('select public.report_tips(%s)', :'F'), 'You do not have the right to see financial reports.');
reset role;
-- bill voided AFTER the tip: still excluded (checked above with c5); an order with no tips -> empty arrays
select t.as_('owner');
select public.report_tips('2026-10-01'::date, '2026-10-02'::date) as tp0 \gset
reset role;
select t.same('5.7 empty period: empty arrays and zero totals (never null)', :'tp0'::jsonb, '{"by_day":[],"by_method":[],"by_waiter":[],"by_outlet":[],"totals":{"tips":0,"amount":0,"bills":0}}');

-- ================================================================ 6. PERMISSIONS, RANGE, EMPTY
select t.as_('nina');
select t.err('6.1 Nina (no report rights) refused ' || f, format('select public.%I(%s)', f, :'F'), 'report.view_sales') from unnest(array['report_covers','report_reprints','report_tips','report_pending_kot','report_pending_bills']) f;
select t.as_('carl');
select t.err('6.2 Carl (sales only) may use ' || f, format('select public.%I(%s)', f, :'F'), 'NO ERROR') from unnest(array['report_covers','report_reprints','report_pending_kot','report_pending_bills']) f;
select t.as_('owner');
select t.err('6.3 366-day limit: ' || f, format('select public.%I(%L::date, %L::date)', f, '2025-01-01', '2026-01-03'), 'Choose a range of one year or less.') from unnest(array['report_covers','report_reprints','report_tips']) f;
select t.err('6.4 reversed range: ' || f, format('select public.%I(%L::date, %L::date)', f, '2026-10-21', '2026-10-20'), 'Choose a valid date range.') from unnest(array['report_covers','report_reprints','report_tips']) f;
select t.err('6.5 null date: ' || f, format('select public.%I(null, %L::date)', f, '2026-10-20'), 'Choose a valid date range.') from unnest(array['report_covers','report_reprints','report_tips']) f;
select t.err('6.6 exactly 366 days is allowed: ' || f, format('select public.%I(%L::date, %L::date)', f, '2025-10-20', '2026-10-21'), 'NO ERROR') from unnest(array['report_covers','report_reprints','report_tips']) f;
select public.report_covers('2026-01-01'::date, '2026-01-02'::date) as cv0, public.report_reprints('2026-01-01'::date, '2026-01-02'::date) as rp0 \gset
reset role;
select t.same('6.7 empty covers period: empty arrays, zero totals, sales per cover null', :'cv0'::jsonb,
  '{"money":true,"by_day":[],"by_outlet":[],"by_waiter":[],"totals":{"bills":0,"bills_with_covers":0,"bills_without_covers":0,"covers":0,"sales":0,"sales_per_cover":null}}');
select t.same('6.8 empty reprints period', :'rp0'::jsonb, '{"rows":[],"by_user":[],"truncated":false,"row_limit":2000,"total_rows":0,"totals":{"reprints":0,"bills":0,"kots":0}}');
select set_config('request.jwt.claim.sub', '', false);
select set_config('role', 'authenticated', false);
select t.err('6.9 signed in as nobody: refused ' || f, format('select public.%I(%s)', f, :'F'), 'not signed in') from unnest(array['report_covers','report_reprints','report_tips']) f;
reset role;
set role anon;
select t.err('6.10 anon has no execute right on ' || f, format('select public.%I(%s)', f, :'F'), 'permission denied') from unnest(array['report_covers','report_reprints','report_tips','report_pending_kot','report_pending_bills']) f;
reset role;

-- ================================================================ 7. REPRINT CAP (2105 rows -> 2000, truncated)
insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, new_value, created_at)
  select t.id('rest1'), t.id('outA'), t.id('carl'), 'bill.reprint', 'orders', t.id('c1'), '{}', '2026-03-10 06:00:00+00'::timestamptz + (g || ' seconds')::interval from generate_series(1, 2105) g;
select t.as_('owner');
select public.report_reprints('2026-03-10'::date, '2026-03-10'::date) as rpc \gset
reset role;
select t.same('7.1 reprints: 2105 rows -> 2000 shown, truncated, totals over all',
  jsonb_build_object('rows', jsonb_array_length(:'rpc'::jsonb -> 'rows'), 'tr', :'rpc'::jsonb -> 'truncated', 'n', :'rpc'::jsonb -> 'total_rows', 'tot', :'rpc'::jsonb -> 'totals'),
  '{"rows":2000,"tr":true,"n":2105,"tot":{"reprints":2105,"bills":2105,"kots":0}}');

-- ================================================================ 8. function hygiene
select t.eq('8.1 all five are STABLE SECURITY DEFINER with a fixed search_path',
  (select to_jsonb(count(*)) from pg_proc where proname in ('report_covers','report_reprints','report_tips','report_pending_kot','report_pending_bills')
     and provolatile = 's' and prosecdef and proconfig::text like '%search_path=public, pg_temp%'), '5');
select t.eq('8.2 no report function left a temp table behind', (select to_jsonb(count(*)) from pg_class where relname like '\_rep\_%' and relpersistence = 't'), '0');

-- ---------------------------------------------------------------- result
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
select case when :failed > 0 then 1/0 end as stop_if_failed;
