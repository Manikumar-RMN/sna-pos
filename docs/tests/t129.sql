-- t129.sql: proves the eight report-pack-2 RPCs of migration 129 on a database with migrations 001..129 applied.
-- Run as a superuser (it creates its own fixtures and impersonates users with SET ROLE authenticated + JWT claims).
-- Run it on a FRESH scratch database (docs/tests/run-t129.sh builds one). Test databases only.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
set session_replication_role = replica;      -- fixtures are written straight into the tables (no billing triggers); the RPCs under test are read-only
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
grant usage on schema t to public; grant all on t.res to public; grant usage on sequence t.res_n_seq to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t129:' || p)::uuid $$;
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
do $$
declare r1 uuid := t.id('rest1'); r2 uuid := t.id('rest2'); a uuid := t.id('outA'); b uuid := t.id('outB'); c uuid := t.id('outC');
  cat uuid := t.id('cat1'); x text;
begin
  insert into public.restaurants (id, legal_name, trading_name, country_code, currency_code, timezone, edition)
    values (r1, 'Test One Pvt Ltd', 'Test One', 'IN', 'INR', 'Asia/Kolkata', 'professional'),
           (r2, 'Test Two Pvt Ltd', 'Test Two', 'IN', 'INR', 'Asia/Kolkata', 'professional');
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone)
    values (a, r1, 'Outlet A', 'A', 'IN', 'Asia/Kolkata'), (b, r1, 'Outlet B', 'B', 'IN', 'Asia/Kolkata'), (c, r2, 'Outlet C', 'C', 'IN', 'Asia/Kolkata');
  insert into public.tax_groups (id, restaurant_id, name) values (t.id('tax1'), r1, 'GST'), (t.id('tax2'), r2, 'GST');
  insert into public.categories (id, restaurant_id, name) values (cat, r1, 'Food'), (t.id('cat2'), r2, 'Food');
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values
    (t.id('burger'), r1, cat, t.id('tax1'), 'Burger', 100), (t.id('pizza'), r1, cat, t.id('tax1'), 'Pizza', 300),
    (t.id('soup'), r1, cat, t.id('tax1'), 'Soup', 80), (t.id('tea'), r1, cat, t.id('tax1'), 'Tea', 20),
    (t.id('coffee'), r1, cat, t.id('tax1'), 'Coffee', 100), (t.id('pasta'), r1, cat, t.id('tax1'), 'Pasta', 150),
    (t.id('burger2'), r2, t.id('cat2'), t.id('tax2'), 'Burger', 100);
  insert into public.roles (id, restaurant_id, name, is_system) values
    (t.id('roleOwner'), r1, 'Owner', true), (t.id('roleMgr'), r1, 'Manager', false), (t.id('roleCashier'), r1, 'Cashier', false), (t.id('roleNobody'), r1, 'Nobody', false),
    (t.id('roleOwner2'), r2, 'Owner', true);
  insert into public.role_permissions (role_id, permission_key) values
    (t.id('roleOwner'), 'report.view_sales'), (t.id('roleOwner'), 'report.view_financial'),
    (t.id('roleMgr'), 'report.view_sales'), (t.id('roleMgr'), 'report.view_financial'),
    (t.id('roleCashier'), 'report.view_sales'),
    (t.id('roleOwner2'), 'report.view_sales'), (t.id('roleOwner2'), 'report.view_financial');
  foreach x in array array['owner','carl','mgr','nina','wendy','wes','other'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t129.test');
  end loop;
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values
    (t.id('owner'), r1, t.id('auth:owner'), 'E1', 'Olivia Owner',  t.id('roleOwner'),   'owner@t129.test'),
    (t.id('carl'),  r1, t.id('auth:carl'),  'E2', 'Carl Cashier',  t.id('roleCashier'), 'carl@t129.test'),
    (t.id('mgr'),   r1, t.id('auth:mgr'),   'E3', 'Maya Manager',  t.id('roleMgr'),     'mgr@t129.test'),
    (t.id('nina'),  r1, t.id('auth:nina'),  'E4', 'Nina Nobody',   t.id('roleNobody'),  'nina@t129.test'),
    (t.id('wendy'), r1, t.id('auth:wendy'), 'E5', 'Wendy Waiter',  t.id('roleCashier'), 'wendy@t129.test'),
    (t.id('wes'),   r1, t.id('auth:wes'),   'E6', 'Wes Waiter',    t.id('roleCashier'), 'wes@t129.test'),
    (t.id('other'), r2, t.id('auth:other'), 'E7', 'Other Owner',   t.id('roleOwner2'),  'other@t129.test');
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (t.id('carl'), a, r1), (t.id('mgr'), a, r1);
  insert into public.payment_methods (id, restaurant_id, name, kind) values
    (t.id('pmCash'), r1, 'Cash', 'cash'), (t.id('pmCard'), r1, 'Card', 'card'), (t.id('pmUpi'), r1, 'UPI', 'upi'),
    (t.id('pmGift'), r1, 'Gift card', 'gift_card'), (t.id('pmCash2'), r2, 'Cash', 'cash');
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number) values
    (t.id('T1'), r1, a, 'T1'), (t.id('T2'), r1, a, 'T2'), (t.id('TB1'), r1, b, 'B1'), (t.id('TC1'), r2, c, 'C1');
end $$;

-- helpers that write fixtures straight into the tables
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
create function t.mk_tax(p_order text, p_item text, p_comp text, p_rate numeric, p_taxable numeric, p_tax numeric) returns void language sql as $$
  insert into public.order_item_taxes (restaurant_id, order_id, order_item_id, component_name, rate, taxable_amount, tax_amount)
  values (t.id('rest1'), t.id(p_order), t.id(p_item), p_comp, p_rate, p_taxable, p_tax) $$;
create function t.mk_pay(k text, p_order text, p_pm text, p_amt numeric, p_status text default 'captured', p_round numeric default 0, p_rest text default 'rest1') returns void language plpgsql as $$
declare d timestamptz;
begin
  select o.created_at + interval '30 minutes' into d from public.orders o where o.id = t.id(p_order);
  insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, received_by, client_created_at, created_at, status, rounding_adjustment, reference_no)
  values (t.id(k), t.id(p_rest), t.id(p_order), t.id(p_pm), p_amt, 'INR', t.id('owner'), d, d, p_status, p_round, 'ref-' || k);
end $$;
create function t.mk_refund(k text, p_order text, p_amt numeric, p_when timestamptz, p_pm text, p_payment text default null) returns void language sql as $$
  insert into public.refunds (id, restaurant_id, order_id, payment_id, amount, reason, approved_by, client_created_at, created_at, payment_method_id)
  values (t.id(k), t.id('rest1'), t.id(p_order), case when p_payment is null then null else t.id(p_payment) end, p_amt, 'test refund', t.id('owner'), p_when, p_when,
          case when p_pm is null then null else t.id(p_pm) end) $$;
create function t.mk_kot(k text, p_order text, p_status text, p_created timestamptz, p_branch text, p_rest text default 'rest1') returns void language sql as $$
  insert into public.kitchen_tickets (id, restaurant_id, branch_id, order_id, ticket_number, station, status, client_created_at, created_at)
  values (t.id(k), t.id(p_rest), t.id(p_branch), t.id(p_order), 'K-' || upper(k), 'Kitchen', p_status, p_created, p_created) $$;
create function t.mk_kitem(k text, p_kot text, p_item text, p_name text, p_qty numeric, p_status text, p_rest text default 'rest1') returns void language sql as $$
  insert into public.kitchen_ticket_items (id, restaurant_id, kitchen_ticket_id, order_item_id, product_name, quantity, status)
  values (t.id(k), t.id(p_rest), t.id(p_kot), t.id(p_item), p_name, p_qty, p_status) $$;
create function t.pick(j jsonb, ks text[]) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg((select jsonb_agg(e -> k order by ord) from unnest(ks) with ordinality as u(k, ord))), '[]'::jsonb) from jsonb_array_elements(j) e $$;
create function t.sr(p_sr jsonb, p_path text[]) returns jsonb language sql immutable as $$ select p_sr #> p_path $$;

-- ===== outlet A =====
-- o1 10-20 split payment cash + UPI. header: sub 500 disc 50 svc 25 tax 24.5 rounding 0.5 grand 500
select t.mk_order('o1', 'outA', '2026-10-20', 'completed', null, 'carl', 'wendy', 2, 500, 50, 25, 24.5, 0.5, 500, 'paid', null, 'T1');
select t.mk_item('i1a', 'o1', 'burger', 'Burger', 2, 100, 190), t.mk_item('i1b', 'o1', 'pizza', 'Pizza', 1, 300, 285);
select t.mk_tax('o1', 'i1a', 'CGST', 2.5, 490, 12.25), t.mk_tax('o1', 'i1a', 'SGST', 2.5, 490, 12.25);
select t.mk_pay('p1a', 'o1', 'pmCash', 300), t.mk_pay('p1b', 'o1', 'pmUpi', 200);
-- o2 10-21 takeaway, card; its soup line is cancelled (sales_report still adds that line's net_amount: mirrored on purpose)
select t.mk_order('o2', 'outA', '2026-10-21', 'completed', null, 'carl', null, null, 200, 0, 0, 10, 0, 210, 'paid');
select t.mk_item('i2a', 'o2', 'burger', 'Burger', 2, 100, 200), t.mk_item('i2b', 'o2', 'soup', 'Soup', 1, 80, 80, true);
select t.mk_tax('o2', 'i2a', 'CGST', 2.5, 200, 5), t.mk_tax('o2', 'i2a', 'SGST', 2.5, 200, 5);
select t.mk_pay('p2', 'o2', 'pmCard', 210);
-- o3 complimentary
select t.mk_order('o3', 'outA', '2026-10-21', 'completed', 'complimentary', 'carl', 'wendy', 2, 300, 100, 0, 0, 0, 0, 'paid', null, 'T1');
select t.mk_item('i3a', 'o3', 'pizza', 'Pizza', 1, 300, 0);
-- o4 voided WITH two audit rows (reason in the audit differs from orders.void_reason, the later audit row wins); o4b voided without audit; o21 voided in B
select t.mk_order('o4', 'outA', '2026-10-21', 'voided', null, 'carl', 'wendy', 3, 1000, 100, 0, 0, 0, 1000, 'unpaid', null, 'T1', 'rest1', null, 'old column reason', 'owner');
select t.mk_item('i4a', 'o4', 'pizza', 'Pizza', 3, 300, 900);
insert into public.audit_logs (restaurant_id, branch_id, user_id, action, entity_type, entity_id, new_value, old_value, created_at) values
  (t.id('rest1'), t.id('outA'), t.id('owner'), 'order.void', 'orders', t.id('o4'), '{"status":"voided","reason":"Customer left"}', '{"status":"completed","grand_total":1000}', '2026-10-21 10:00:00+00'),
  (t.id('rest1'), t.id('outA'), t.id('owner'), 'order.void', 'orders', t.id('o4'), '{"status":"voided","reason":"Customer left (latest wins)"}', null, '2026-10-21 11:00:00+00');
select t.mk_order('o4b', 'outA', '2026-10-22', 'voided', null, 'carl', null, null, 250, 0, 0, 0, 0, 250, 'unpaid', null, null, 'rest1', null, 'manager decision', 'mgr');
select t.mk_order('o21', 'outB', '2026-10-20', 'voided', null, 'owner', 'wes', 2, 90, 0, 0, 0, 0, 90, 'unpaid', null, 'TB1', 'rest1', null, 'test void', 'owner');
-- out of range / merged / zero
select t.mk_order('o5', 'outA', '2026-10-19', 'completed', null, 'carl', 'wendy', 2, 500, 50, 0, 0, 0, 450, 'paid');
select t.mk_item('i5a', 'o5', 'burger', 'Burger', 5, 100, 450);
select t.mk_order('o6', 'outA', '2026-10-20', 'completed', null, 'carl', 'wendy', 2, 400, 40, 0, 0, 0, 360, 'paid', 'o1');
select t.mk_item('i6a', 'o6', 'burger', 'Burger', 4, 100, 360);
select t.mk_order('o9', 'outA', '2026-10-22', 'completed', null, 'carl', null, null, 0, 30, 0, 0, 0, 0, 'paid');
-- o12 billed, nothing paid (credit); o13 billed, part paid (cash 250 incl. 0.4 cash rounding)
select t.mk_order('o12', 'outA', '2026-10-22', 'completed', null, 'carl', 'wendy', 2, 400, 0, 0, 20, 0, 420, 'unpaid', null, 'T2');
select t.mk_item('i12a', 'o12', 'burger', 'Burger', 4, 100, 400);
select t.mk_tax('o12', 'i12a', 'CGST', 2.5, 400, 10), t.mk_tax('o12', 'i12a', 'SGST', 2.5, 400, 10);
select t.mk_order('o13', 'outA', '2026-10-22', 'completed', null, 'carl', 'wendy', 3, 560, 0, 0, 40, 0, 600, 'partial', null, 'T1');
select t.mk_item('i13a', 'o13', 'pizza', 'Pizza', 2, 280, 560);
select t.mk_tax('o13', 'i13a', 'CGST', 2.5, 560, 20), t.mk_tax('o13', 'i13a', 'SGST', 2.5, 560, 20);
select t.mk_pay('p13', 'o13', 'pmCash', 250, 'captured', 0.4);
-- open orders (kitchen): o14 open with an advance, o15 placed (ticket ready), o16 served, o17 open but after the range
select t.mk_order('o14', 'outA', '2026-10-22', 'open', null, 'carl', 'wendy', 2, 180, 0, 0, 0, 0, 180, 'unpaid', null, 'T2', 'rest1', now() - interval '2 hours');
select t.mk_item('i14a', 'o14', 'burger', 'Burger', 1, 100), t.mk_item('i14b', 'o14', 'tea', 'Tea', 2, 20), t.mk_item('i14c', 'o14', 'soup', 'Soup', 1, 80),
       t.mk_item('i14d', 'o14', 'pizza', 'Pizza', 1, 300, 0, true);
select t.mk_pay('p14', 'o14', 'pmCash', 50);
select t.mk_kot('k14a', 'o14', 'preparing', now() - interval '90 minutes', 'outA');
select t.mk_kitem('ki14a', 'k14a', 'i14a', 'Burger', 1, 'new'), t.mk_kitem('ki14b', 'k14a', 'i14b', 'Tea', 2, 'preparing'),
       t.mk_kitem('ki14c', 'k14a', 'i14c', 'Soup', 1, 'served'), t.mk_kitem('ki14d', 'k14a', 'i14d', 'Pizza', 1, 'new');      -- last one: bill line cancelled
select t.mk_kot('k14b', 'o14', 'ready', now() - interval '30 minutes', 'outA');
select t.mk_kitem('ki14e', 'k14b', 'i14a', 'Burger', 1, 'ready');
select t.mk_kot('k14c', 'o14', 'new', now() - interval '20 minutes', 'outA'), t.mk_kitem('ki14f', 'k14c', 'i14d', 'Pizza', 1, 'new');   -- ticket whose only pending line was cancelled on the bill: must not be listed
select t.mk_order('o15', 'outA', '2026-10-22', 'placed', null, 'carl', 'wendy', 2, 90, 0, 0, 0, 0, 90, 'unpaid', null, 'T1', 'rest1', now() - interval '40 minutes');
select t.mk_item('i15a', 'o15', 'pasta', 'Pasta', 1, 90);
select t.mk_kot('k15', 'o15', 'ready', now() - interval '35 minutes', 'outA'), t.mk_kitem('ki15', 'k15', 'i15a', 'Pasta', 1, 'ready');
select t.mk_order('o16', 'outA', '2026-10-21', 'served', null, 'carl', null, null, 120, 0, 0, 0, 0, 120, 'unpaid', null, 'T2', 'rest1', now() - interval '26 hours');
select t.mk_item('i16a', 'o16', 'coffee', 'Coffee', 1, 100), t.mk_item('i16b', 'o16', 'pasta', 'Pasta', 2, 10, 0, true), t.mk_item('i16c', 'o16', 'tea', 'Tea', 1, 20);
select t.mk_kot('k16a', 'o16', 'cancelled', now() - interval '25 hours', 'outA'), t.mk_kitem('ki16a', 'k16a', 'i16c', 'Tea', 1, 'new');
select t.mk_kot('k16b', 'o16', 'new', now() - interval '24 hours', 'outA');
select t.mk_kitem('ki16b', 'k16b', 'i16a', 'Coffee', 1, 'new'), t.mk_kitem('ki16c', 'k16b', 'i16b', 'Pasta', 2, 'new');      -- pasta line cancelled on the bill
select t.mk_order('o17', 'outA', '2026-10-25', 'open', null, 'carl', 'wendy', 2, 50, 0, 0, 0, 0, 50, 'unpaid', null, 'T1', 'rest1', now() - interval '5 minutes');
select t.mk_item('i17a', 'o17', 'tea', 'Tea', 2, 25);
select t.mk_kot('k17', 'o17', 'new', now() - interval '5 minutes', 'outA'), t.mk_kitem('ki17', 'k17', 'i17a', 'Tea', 2, 'new');
-- ===== outlet B =====
select t.mk_order('o7', 'outB', '2026-10-20', 'completed', null, 'owner', 'wes', 4, 800, 200, 40, 30, 0, 670, 'paid', null, 'TB1');
select t.mk_item('i7a', 'o7', 'pizza', 'Pizza', 2, 400, 640);
select t.mk_tax('o7', 'i7a', 'CGST', 2.5, 640, 15), t.mk_tax('o7', 'i7a', 'SGST', 2.5, 640, 15);
select t.mk_pay('p7a', 'o7', 'pmCash', 400), t.mk_pay('p7b', 'o7', 'pmCard', 270), t.mk_pay('p7f', 'o7', 'pmCash', 40, 'failed');   -- a failed attempt, not money
select t.mk_order('o8', 'outB', '2026-10-22', 'completed', null, 'owner', 'wendy', 3, 400, 40, 0, 18, 0, 378, 'paid');
select t.mk_item('i8a', 'o8', 'burger', 'Burger', 4, 100, 360);
select t.mk_tax('o8', 'i8a', 'IGST', 5, 360, 18);
select t.mk_pay('p8', 'o8', 'pmGift', 378);
select t.mk_order('o10', 'outB', '2026-10-23', 'completed', null, 'owner', 'wes', 2, 2700, 0, 0, 0, 0, 2700, 'paid');
select t.mk_item('i10a', 'o10', 'pizza', 'Pizza', 9, 300, 2700);
select t.mk_pay('p10', 'o10', 'pmCash', 2700);
select t.mk_order('o18', 'outB', '2026-10-21', 'completed', null, 'owner', 'wes', 2, 500, 0, 0, 0, 0, 500, 'partially_refunded', null, 'TB1');
select t.mk_item('i18a', 'o18', 'pizza', 'Pizza', 1, 500, 500);
select t.mk_pay('p18', 'o18', 'pmCash', 500);
select t.mk_order('o20', 'outB', '2026-10-21', 'open', null, 'owner', 'wes', 2, 60, 0, 0, 0, 0, 60, 'unpaid', null, 'TB1', 'rest1', now() - interval '10 minutes');
select t.mk_item('i20a', 'o20', 'tea', 'Tea', 3, 20);
select t.mk_kot('k20', 'o20', 'new', now() - interval '10 minutes', 'outB'), t.mk_kitem('ki20', 'k20', 'i20a', 'Tea', 3, 'new');
-- refunds: B cash 100 (in range); A 70 on o1's cash payment (mode derived from the payment); A card 25 at 23:30 IST on 22 Oct (in range);
-- A card 15 at 00:30 IST on 23 Oct (out); B 50 on 25 Oct (out)
select t.mk_refund('rf1', 'o18', 100, '2026-10-21 06:30:00+00', 'pmCash');
select t.mk_refund('rf2', 'o1', 70, '2026-10-22 06:30:00+00', null, 'p1a');
select t.mk_refund('rf3', 'o2', 25, '2026-10-22 18:00:00+00', 'pmCard');
select t.mk_refund('rf4', 'o2', 15, '2026-10-22 19:00:00+00', 'pmCard');
select t.mk_refund('rf5', 'o18', 50, '2026-10-25 06:30:00+00', 'pmCash');
-- ===== other restaurant =====
select t.mk_order('o11', 'outC', '2026-10-21', 'completed', null, 'other', 'other', 2, 100, 10, 0, 0, 0, 90, 'paid', null, 'TC1', 'rest2');
select t.mk_item('i11a', 'o11', 'burger2', 'Burger', 1, 100, 90, false, 'rest2');
select t.mk_pay('p11', 'o11', 'pmCash2', 90, 'captured', 0, 'rest2');
select t.mk_order('o19', 'outC', '2026-10-21', 'open', null, 'other', 'other', 2, 100, 0, 0, 0, 0, 100, 'unpaid', null, 'TC1', 'rest2', now() - interval '3 hours');
select t.mk_item('i19a', 'o19', 'burger2', 'Burger', 1, 100, 0, false, 'rest2');
select t.mk_kot('k19', 'o19', 'new', now() - interval '3 hours', 'outC', 'rest2'), t.mk_kitem('ki19', 'k19', 'i19a', 'Burger', 1, 'new', 'rest2');
-- ===== bulk, March 2026, outlet B: 2105 completed bills with one cash payment each (10), 2003 voided bills (cap tests)
insert into public.orders (id, restaurant_id, branch_id, bill_number, order_type, cashier_id, currency_code, client_created_at, created_at, business_date, status, payment_status, subtotal, grand_total)
select t.id('bulk' || n), t.id('rest1'), t.id('outB'), 'BULK' || n, 'takeaway', t.id('owner'), 'INR', '2026-03-10 08:00:00+00'::timestamptz + n * interval '1 second', '2026-03-10 08:00:00+00'::timestamptz + n * interval '1 second', '2026-03-10', 'completed', 'paid', 10, 10
  from generate_series(1, 2105) n;
insert into public.payments (id, restaurant_id, order_id, payment_method_id, amount, currency_code, received_by, client_created_at, created_at, status)
select t.id('bulkp' || n), t.id('rest1'), t.id('bulk' || n), t.id('pmCash'), 10, 'INR', t.id('owner'), '2026-03-10 08:00:00+00'::timestamptz + n * interval '1 second', '2026-03-10 08:00:00+00'::timestamptz + n * interval '1 second', 'captured'
  from generate_series(1, 2105) n;
insert into public.orders (id, restaurant_id, branch_id, bill_number, order_type, cashier_id, currency_code, client_created_at, created_at, business_date, status, payment_status, subtotal, grand_total, voided_by, void_reason, voided_at)
select t.id('bulkv' || n), t.id('rest1'), t.id('outB'), 'BULKV' || n, 'takeaway', t.id('owner'), 'INR', '2026-03-11 08:00:00+00'::timestamptz + n * interval '1 second', '2026-03-11 08:00:00+00'::timestamptz + n * interval '1 second', '2026-03-11', 'voided', 'unpaid', 5, 5, t.id('owner'), 'bulk void', '2026-03-11 09:00:00+00'
  from generate_series(1, 2003) n;
-- exactly 2000 bills on 5 Apr (not truncated) and 2001 bills on 6 Apr (truncated): the edge of the cap
insert into public.orders (id, restaurant_id, branch_id, bill_number, order_type, cashier_id, currency_code, client_created_at, created_at, business_date, status, payment_status, subtotal, grand_total)
select t.id('edge' || d || '_' || n), t.id('rest1'), t.id('outB'), 'EDGE' || d || '_' || n, 'takeaway', t.id('owner'), 'INR', ('2026-04-0' || d || ' 08:00:00+00')::timestamptz + n * interval '1 second', ('2026-04-0' || d || ' 08:00:00+00')::timestamptz + n * interval '1 second', ('2026-04-0' || d)::date, 'completed', 'paid', 1, 1
  from (values (5, 2000), (6, 2001)) v(d, cnt), generate_series(1, 2001) n where n <= v.cnt;
reset session_replication_role;
update public.users set current_branch_id = t.id('outA'), all_outlets = false where id = t.id('owner');
\set F '\'2026-10-20\'::date, \'2026-10-22\'::date'

-- ---------------------------------------------------------------- reconciliation helper: every report against sales_report(119) for the same range and scope
-- p_failed = money of 'failed' payments in the scope: sales_report by_method adds them (it has no status filter), settlement does not.
create function t.recon(p_label text, sr jsonb, bd jsonb, db jsonb, st jsonb, vb jsonb, tx jsonb, pb jsonb, p_failed numeric) returns void language plpgsql as $$
declare s jsonb := sr -> 'summary';
begin
  perform t.same(p_label || ' bills_detail totals = sales_report (grand total=total_billed, tax, service charge, rounding, number of completed bills)',
    jsonb_build_object('gt', bd #> '{totals,grand_total}', 'tax', bd #> '{totals,tax}', 'svc', bd #> '{totals,service_charge}', 'rnd', bd #> '{totals,rounding}', 'n', bd #> '{totals,bills}'),
    jsonb_build_object('gt', s -> 'total_billed', 'tax', s -> 'tax', 'svc', s -> 'service_charge', 'rnd', s -> 'rounding',
                       'n', (s ->> 'bills')::int + (s ->> 'complimentary_bills')::int + (s ->> 'staff_meal_bills')::int)::text);
  perform t.same(p_label || ' day book totals = sales_report summary (bills, gross, discount, service, tax, rounding, net, grand total, unpaid)',
    ((db -> 'totals') - 'comp_bills'::text - 'cash'::text - 'non_cash'::text),
    jsonb_build_object('bills', s -> 'bills', 'gross', s -> 'gross_sales', 'discount', s -> 'discounts', 'service_charge', s -> 'service_charge', 'tax', s -> 'tax',
                       'rounding', s -> 'rounding', 'net_sales', s -> 'net_sales', 'grand_total', s -> 'total_billed', 'unpaid', s -> 'unpaid_amount')::text);
  perform t.same(p_label || ' day book rows = sales_report by_day (day, all completed bills, total)',
    (select coalesce(jsonb_agg(jsonb_build_array(e ->> 'business_date', (e ->> 'bills')::int + (e ->> 'comp_bills')::int, e -> 'grand_total') order by ord), '[]'::jsonb) from jsonb_array_elements(db -> 'rows') with ordinality x(e, ord)),
    (select coalesce(jsonb_agg(jsonb_build_array(e ->> 'day', e -> 'bills', e -> 'total') order by ord), '[]'::jsonb) from jsonb_array_elements(sr -> 'by_day') with ordinality x(e, ord))::text);
  perform t.same(p_label || ' day book cash + non_cash = settlement total amount',
    jsonb_build_object('sum', (db #>> '{totals,cash}')::numeric + (db #>> '{totals,non_cash}')::numeric), jsonb_build_object('sum', st #> '{totals,amount}')::text);
  perform t.same(p_label || ' settlement by mode = sales_report by_method (only difference: failed payments, ' || p_failed || ')',
    (select coalesce(jsonb_object_agg(e ->> 'method', e -> 'amount'), '{}'::jsonb) from jsonb_array_elements(st -> 'by_mode') e),
    (select coalesce(jsonb_object_agg(e ->> 'method', case when e ->> 'method' = 'Cash' then to_jsonb((e ->> 'amount')::numeric - p_failed) else e -> 'amount' end), '{}'::jsonb)
       from jsonb_array_elements(sr -> 'by_method') e where not (e ->> 'method' = 'Cash' and (e ->> 'amount')::numeric - p_failed = 0))::text);
  perform t.same(p_label || ' settlement refunds = sales_report refunds / refund_count',
    jsonb_build_object('a', st #> '{refunds,amount}', 'n', st #> '{refunds,count}'), jsonb_build_object('a', s -> 'refunds', 'n', s -> 'refund_count')::text);
  perform t.same(p_label || ' void bills totals = sales_report voided_bills / voided_value',
    vb -> 'totals', jsonb_build_object('bills', s -> 'voided_bills', 'amount', s -> 'voided_value')::text);
  perform t.same(p_label || ' tax report rows = sales_report tax list (component, rate, taxable, tax)',
    (select coalesce(jsonb_agg(jsonb_build_array(e -> 'component', e -> 'rate', e -> 'taxable', e -> 'tax') order by ord), '[]'::jsonb) from jsonb_array_elements(tx -> 'rows') with ordinality x(e, ord)),
    (select coalesce(jsonb_agg(jsonb_build_array(e -> 'component', e -> 'rate', e -> 'taxable', e -> 'tax') order by ord), '[]'::jsonb) from jsonb_array_elements(sr -> 'tax') with ordinality x(e, ord))::text);
  perform t.same(p_label || ' tax report: line total = bill-header tax total = sales_report tax',
    jsonb_build_object('lines', tx #> '{totals,tax}', 'hdr', tx #> '{totals,orders_tax_total}'), jsonb_build_object('lines', s -> 'tax', 'hdr', s -> 'tax')::text);
  perform t.same(p_label || ' pending bills: unsettled rows = sales_report unpaid_bills / unpaid_amount',
    jsonb_build_object('n', (select count(*) from jsonb_array_elements(pb -> 'rows') r where r ->> 'kind' = 'unsettled'),
                       'bal', (select coalesce(sum((r ->> 'balance')::numeric), 0) from jsonb_array_elements(pb -> 'rows') r where r ->> 'kind' = 'unsettled')),
    jsonb_build_object('n', s -> 'unpaid_bills', 'bal', s -> 'unpaid_amount')::text);
end $$;

-- ---------------------------------------------------------------- 1. OWNER, ALL OUTLETS
update public.users set all_outlets = true, current_branch_id = t.id('outA') where id = t.id('owner');
select t.as_('owner');
select public.report_pending_kot(:F) as kot, public.report_pending_bills(:F) as pb, public.report_bills_detail(:F) as bd, public.report_void_bills(:F) as vb,
       public.report_settlement(:F) as st, public.report_sales_day_book(:F) as db, public.report_sales_month_book(:F) as mb, public.report_tax(:F) as tx,
       public.sales_report(:F) as sr \gset
reset role;
select t.eq('0.0 owner is on All outlets (my_outlets) while current_branch_id is A', (select to_jsonb(all_outlets) from public.users where id = t.id('owner')), 'true');

select t.same('1.1a pending KOT (All): k16b (Coffee only: Pasta line cancelled on the bill; ticket k16a cancelled), k14a (Burger new + Tea preparing; Soup served and Pizza cancelled line left out), k20 in outlet B; not k14b / k15 (ready), not k17 (after range), not the other restaurant',
  t.pick(:'kot'::jsonb -> 'rows', array['ticket_number','outlet_name','table_number','bill_number','order_status']),
  '[["K-K16B","Outlet A","T2","O16","served"],["K-K14A","Outlet A","T2","O14","open"],["K-K20","Outlet B","B1","O20","open"]]');
select t.same('1.1b pending KOT items (by line order, then name) and totals', jsonb_build_object('i', (select jsonb_agg(r -> 'items' order by ord) from jsonb_array_elements(:'kot'::jsonb -> 'rows') with ordinality x(r, ord)), 't', :'kot'::jsonb -> 'totals'),
  '{"i":[[{"name":"Coffee","quantity":1,"status":"new","note":null}],[{"name":"Burger","quantity":1,"status":"new","note":null},{"name":"Tea","quantity":2,"status":"preparing","note":null}],[{"name":"Tea","quantity":3,"status":"new","note":null}]],"t":{"kots":3,"items":4}}');
select t.eq('1.1c minutes pending: k14a created 90 min ago -> 90, k16b 24 h ago -> 1440, k20 10 min -> 10',
  jsonb_build_array((:'kot'::jsonb -> 'rows' -> 1 ->> 'minutes_pending')::int between 90 and 91, (:'kot'::jsonb -> 'rows' -> 0 ->> 'minutes_pending')::int between 1440 and 1441, (:'kot'::jsonb -> 'rows' -> 2 ->> 'minutes_pending')::int between 10 and 11), '[true,true,true]');

select t.same('1.2a pending bills (All): unsettled o12 420 and o13 600 (paid 249.6, balance 350.4), open o16 120, o14 180 (advance 50 -> 130), o15 90, o20 60 in B; not o17 (after range), not the paid / voided bills',
  t.pick(:'pb'::jsonb -> 'rows', array['bill_number','kind','amount','paid','balance','outlet_name']),
  '[["O12","unsettled",420,0,420,"Outlet A"],["O13","unsettled",600,249.6,350.4,"Outlet A"],["O16","open",120,0,120,"Outlet A"],["O14","open",180,50,130,"Outlet A"],["O15","open",90,0,90,"Outlet A"],["O20","open",60,0,60,"Outlet B"]]');
select t.same('1.2b pending bills totals', :'pb'::jsonb -> 'totals', '{"bills":6,"amount":1470,"paid":299.6,"balance":1170.4}');
select t.same('1.2c pending bills o14: table, waiter, cashier, status, age (created 2 h ago)',
  (select jsonb_build_array(r ->> 'table_number', r ->> 'waiter', r ->> 'cashier', r ->> 'order_status', r ->> 'payment_status', (r ->> 'age_minutes')::int between 120 and 121) from jsonb_array_elements(:'pb'::jsonb -> 'rows') r where r ->> 'bill_number' = 'O14'),
  '["T2","Wendy Waiter","Carl Cashier","open","unpaid",true]');

select t.same('1.3a bills detail (All): 9 completed bills, oldest first (merged o6, voided, other days, other restaurant left out; complimentary o3 included)',
  t.pick(:'bd'::jsonb -> 'rows', array['bill_number','business_date','outlet_name','table_number','order_type','grand_total']),
  '[["O1","2026-10-20","Outlet A","T1","dine_in",500],["O7","2026-10-20","Outlet B","B1","dine_in",670],["O18","2026-10-21","Outlet B","B1","dine_in",500],["O2","2026-10-21","Outlet A",null,"takeaway",210],["O3","2026-10-21","Outlet A","T1","dine_in",0],["O12","2026-10-22","Outlet A","T2","dine_in",420],["O13","2026-10-22","Outlet A","T1","dine_in",600],["O8","2026-10-22","Outlet B",null,"takeaway",378],["O9","2026-10-22","Outlet A",null,"takeaway",0]]');
select t.same('1.3b bills detail o1: waiter, cashier, covers, money columns, split payments',
  (select jsonb_build_object('w', r ->> 'waiter', 'c', r ->> 'cashier', 'cv', r -> 'covers', 'sub', r -> 'subtotal', 'disc', r -> 'discount', 'svc', r -> 'service_charge', 'tax', r -> 'tax', 'rnd', r -> 'rounding', 'gt', r -> 'grand_total', 'pay', r -> 'payments')
     from jsonb_array_elements(:'bd'::jsonb -> 'rows') r where r ->> 'bill_number' = 'O1'),
  '{"w":"Wendy Waiter","c":"Carl Cashier","cv":2,"sub":500,"disc":50,"svc":25,"tax":24.5,"rnd":0.5,"gt":500,"pay":[{"method":"Cash","kind":"cash","amount":300},{"method":"UPI","kind":"upi","amount":200}]}');
select t.same('1.3c bills detail: failed payment not listed on o7; o3 shows comp_kind; unpaid o12 has no payments',
  jsonb_build_object('o7', (select r -> 'payments' from jsonb_array_elements(:'bd'::jsonb -> 'rows') r where r ->> 'bill_number' = 'O7'),
                     'o3', (select r ->> 'comp_kind' from jsonb_array_elements(:'bd'::jsonb -> 'rows') r where r ->> 'bill_number' = 'O3'),
                     'o12', (select r -> 'payments' from jsonb_array_elements(:'bd'::jsonb -> 'rows') r where r ->> 'bill_number' = 'O12')),
  '{"o7":[{"method":"Card","kind":"card","amount":270},{"method":"Cash","kind":"cash","amount":400}],"o3":"complimentary","o12":[]}');
select t.same('1.3d bills detail totals and flags (hand sums: subtotal 3660, discount 420, service 65, tax 142.5, rounding 0.5, grand 3278)',
  jsonb_build_object('t', :'bd'::jsonb -> 'totals', 'trunc', :'bd'::jsonb -> 'truncated', 'n', :'bd'::jsonb -> 'total_rows', 'lim', :'bd'::jsonb -> 'row_limit'),
  '{"t":{"bills":9,"subtotal":3660,"discount":420,"service_charge":65,"tax":142.5,"rounding":0.5,"grand_total":3278},"trunc":false,"n":9,"lim":2000}');

select t.same('1.4a void bills (All): o21 (B), o4 (A; the LATEST audit reason beats orders.void_reason), o4b (A, 22 Oct; no audit row: orders.void_reason; voided by Maya)',
  t.pick(:'vb'::jsonb -> 'rows', array['bill_number','business_date','outlet_name','voided_by','reason','amount']),
  '[["O21","2026-10-20","Outlet B","Olivia Owner","test void",90],["O4","2026-10-21","Outlet A","Olivia Owner","Customer left (latest wins)",1000],["O4B","2026-10-22","Outlet A","Maya Manager","manager decision",250]]');
select t.same('1.4b void bills totals, void time, table', jsonb_build_object('t', :'vb'::jsonb -> 'totals', 'tr', :'vb'::jsonb -> 'truncated', 'time', (:'vb'::jsonb -> 'rows' -> 1 ->> 'voided_at')::timestamptz, 'tbl', :'vb'::jsonb -> 'rows' -> 1 -> 'table_number'),
  '{"t":{"bills":3,"amount":1340},"tr":false,"time":"2026-10-21T09:00:00+00:00","tbl":"T1"}');

select t.same('1.5a settlement by mode (All): Cash 4 payments / 4 bills 1450 (failed 40 not counted; includes o13 cash rounding 0.4), Card 480, Gift card 378, UPI 200',
  t.pick(:'st'::jsonb -> 'by_mode', array['method','kind','payments','bills','amount','rounding']),
  '[["Cash","cash",4,4,1450,0.4],["Card","card",2,2,480,0],["Gift card","gift_card",1,1,378,0],["UPI","upi",1,1,200,0]]');
select t.same('1.5b settlement by outlet (All)',
  t.pick(:'st'::jsonb -> 'by_outlet', array['outlet_name','method','payments','bills','amount']),
  '[["Outlet A","Cash",2,2,550],["Outlet A","Card",1,1,210],["Outlet A","UPI",1,1,200],["Outlet B","Cash",2,2,900],["Outlet B","Gift card",1,1,378],["Outlet B","Card",1,1,270]]');
select t.same('1.5c settlement refunds (All): 3 in range = 195 (cash 100 + 70 derived from the payment, card 25 at 23:30 IST on the 22nd; the 00:30 IST one on the 23rd and the one on 25 Oct are out)',
  :'st'::jsonb -> 'refunds',
  format('{"count":3,"amount":195,"by_mode":[{"method":"Cash","kind":"cash","count":2,"amount":170},{"method":"Card","kind":"card","count":1,"amount":25}],"by_outlet":[{"branch_id":"%s","outlet_name":"Outlet A","count":2,"amount":95},{"branch_id":"%s","outlet_name":"Outlet B","count":1,"amount":100}]}', t.id('outA'), t.id('outB')));
select t.same('1.5d settlement detail rows (All): 9 captured payments on completed bills (no advance on the open o14, no failed p7f, no o10 of the 23rd, no other restaurant), totals',
  jsonb_build_object('r', t.pick(:'st'::jsonb -> 'rows', array['bill_number','method','amount','rounding','reference_no','received_by']), 'tr', :'st'::jsonb -> 'truncated', 'n', :'st'::jsonb -> 'total_rows', 't', :'st'::jsonb -> 'totals'),
  '{"r":[["O1","Cash",300,0,"ref-p1a","Olivia Owner"],["O1","UPI",200,0,"ref-p1b","Olivia Owner"],["O7","Card",270,0,"ref-p7b","Olivia Owner"],["O7","Cash",400,0,"ref-p7a","Olivia Owner"],["O18","Cash",500,0,"ref-p18","Olivia Owner"],["O2","Card",210,0,"ref-p2","Olivia Owner"],["O13","Cash",250,0.4,"ref-p13","Olivia Owner"],["O8","Gift card",378,0,"ref-p8","Olivia Owner"]],"tr":false,"n":8,"t":{"payments":8,"amount":2508,"rounding":0.4,"refunds":195,"net":2313}}');

select t.same('1.6a day book (All): 3 business days',
  t.pick(:'db'::jsonb -> 'rows', array['business_date','bills','comp_bills','gross','discount','service_charge','tax','rounding','net_sales','grand_total','cash','non_cash','unpaid']),
  '[["2026-10-20",2,0,1300,250,65,54.5,0.5,1115,1170,700,470,0],["2026-10-21",2,1,700,0,0,10,0,780,710,500,210,0],["2026-10-22",4,0,1360,70,0,78,0,1320,1398,250,378,770.4]]');
select t.same('1.6b day book totals (hand sums: 8 bills + 1 comp, gross 3360, discount 320, service 65, tax 142.5, rounding 0.5, net 3215, grand 3278, cash 1450, non-cash 1058, unpaid 770.4)',
  :'db'::jsonb -> 'totals',
  '{"bills":8,"comp_bills":1,"gross":3360,"discount":320,"service_charge":65,"tax":142.5,"rounding":0.5,"net_sales":3215,"grand_total":3278,"cash":1450,"non_cash":1058,"unpaid":770.4}');
select t.same('1.6c month book (All, same 3 days): one row 2026-10 with the same totals, days 3',
  jsonb_build_object('rows', t.pick(:'mb'::jsonb -> 'rows', array['month','days','bills','comp_bills','gross','discount','service_charge','tax','rounding','net_sales','grand_total','cash','non_cash','unpaid']), 't', :'mb'::jsonb -> 'totals'),
  '{"rows":[["2026-10",3,8,1,3360,320,65,142.5,0.5,3215,3278,1450,1058,770.4]],"t":{"days":3,"bills":8,"comp_bills":1,"gross":3360,"discount":320,"service_charge":65,"tax":142.5,"rounding":0.5,"net_sales":3215,"grand_total":3278,"cash":1450,"non_cash":1058,"unpaid":770.4}}');

select t.same('1.7a tax report (All): CGST 2.5 % taxable 2290 tax 62.25, SGST 2.5 % same, IGST 5 % taxable 360 tax 18; totals = bill headers',
  jsonb_build_object('rows', :'tx'::jsonb -> 'rows', 't', :'tx'::jsonb -> 'totals'),
  '{"rows":[{"component":"CGST","rate":2.5,"taxable":2290,"tax":62.25},{"component":"SGST","rate":2.5,"taxable":2290,"tax":62.25},{"component":"IGST","rate":5,"taxable":360,"tax":18}],"t":{"taxable":4940,"tax":142.5,"orders_tax_total":142.5,"tax_included":0,"exempt_sales":0}}');
select t.same('1.7b tax report by outlet (All)',
  t.pick(:'tx'::jsonb -> 'by_outlet', array['outlet_name','component','rate','taxable','tax']),
  '[["Outlet A","CGST",2.5,1650,47.25],["Outlet A","SGST",2.5,1650,47.25],["Outlet B","CGST",2.5,640,15],["Outlet B","SGST",2.5,640,15],["Outlet B","IGST",5,360,18]]');
select t.recon('1.8 [All]', :'sr'::jsonb, :'bd'::jsonb, :'db'::jsonb, :'st'::jsonb, :'vb'::jsonb, :'tx'::jsonb, :'pb'::jsonb, 40);

-- ---------------------------------------------------------------- 2. OWNER, OUTLET A ONLY
update public.users set all_outlets = false, current_branch_id = t.id('outA') where id = t.id('owner');
select t.as_('owner');
select public.report_pending_kot(:F) as kot, public.report_pending_bills(:F) as pb, public.report_bills_detail(:F) as bd, public.report_void_bills(:F) as vb,
       public.report_settlement(:F) as st, public.report_sales_day_book(:F) as db, public.report_sales_month_book(:F) as mb, public.report_tax(:F) as tx,
       public.sales_report(:F) as sr \gset
reset role;
select t.same('2.1 outlet A: pending KOT = k16b, k14a; pending bills = o12 o13 o16 o14 o15; bills detail 6 bills; void bills o4, o4b',
  jsonb_build_object('kot', t.names(:'kot'::jsonb -> 'rows', 'ticket_number'), 'pb', t.names(:'pb'::jsonb -> 'rows', 'bill_number'), 'bd', t.names(:'bd'::jsonb -> 'rows', 'bill_number'), 'vb', t.names(:'vb'::jsonb -> 'rows', 'bill_number')),
  '{"kot":["K-K16B","K-K14A"],"pb":["O12","O13","O16","O14","O15"],"bd":["O1","O2","O3","O12","O13","O9"],"vb":["O4","O4B"]}');
select t.same('2.2 outlet A: settlement 960 (Cash 550, Card 210, UPI 200), refunds 95, net 865; day book grand 500+210+0+0+420+600 = 1730; tax lines CGST 47.25 SGST 47.25 only',
  jsonb_build_object('modes', t.pick(:'st'::jsonb -> 'by_mode', array['method','amount']), 'st', :'st'::jsonb -> 'totals', 'grand', :'db'::jsonb #> '{totals,grand_total}', 'tax', t.pick(:'tx'::jsonb -> 'rows', array['component','tax']), 'outlets', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'st'::jsonb -> 'by_outlet') e)),
  '{"modes":[["Cash",550],["Card",210],["UPI",200]],"st":{"payments":4,"amount":960,"rounding":0.4,"refunds":95,"net":865},"grand":1730,"tax":[["CGST",47.25],["SGST",47.25]],"outlets":["Outlet A"]}');
select t.recon('2.3 [outlet A]', :'sr'::jsonb, :'bd'::jsonb, :'db'::jsonb, :'st'::jsonb, :'vb'::jsonb, :'tx'::jsonb, :'pb'::jsonb, 0);

-- ---------------------------------------------------------------- 3. OWNER, OUTLET B ONLY
update public.users set current_branch_id = t.id('outB') where id = t.id('owner');
select t.as_('owner');
select public.report_pending_kot(:F) as kot, public.report_pending_bills(:F) as pb, public.report_bills_detail(:F) as bd, public.report_void_bills(:F) as vb,
       public.report_settlement(:F) as st, public.report_sales_day_book(:F) as db, public.report_tax(:F) as tx, public.sales_report(:F) as sr \gset
reset role;
select t.same('3.1 outlet B: pending KOT = k20; pending bills = o20; bills detail o7 o18 o8; void bills o21; settlement 1548, refunds 100; tax CGST 15 SGST 15 IGST 18',
  jsonb_build_object('kot', t.names(:'kot'::jsonb -> 'rows', 'ticket_number'), 'pb', t.names(:'pb'::jsonb -> 'rows', 'bill_number'), 'bd', t.names(:'bd'::jsonb -> 'rows', 'bill_number'), 'vb', t.names(:'vb'::jsonb -> 'rows', 'bill_number'),
                     'st', :'st'::jsonb -> 'totals', 'tax', t.pick(:'tx'::jsonb -> 'rows', array['component','tax'])),
  '{"kot":["K-K20"],"pb":["O20"],"bd":["O7","O18","O8"],"vb":["O21"],"st":{"payments":4,"amount":1548,"rounding":0,"refunds":100,"net":1448},"tax":[["CGST",15],["SGST",15],["IGST",18]]}');
select t.recon('3.2 [outlet B]', :'sr'::jsonb, :'bd'::jsonb, :'db'::jsonb, :'st'::jsonb, :'vb'::jsonb, :'tx'::jsonb, :'pb'::jsonb, 40);

-- ---------------------------------------------------------------- 4. RESTRICTED USERS (work only in outlet A)
-- Maya: manager restricted to A, financial right. Even with the all-outlets flag forced on and current outlet forced to B she sees outlet A only.
reset role;
update public.users set all_outlets = true, current_branch_id = t.id('outB') where id = t.id('mgr');
select t.as_('mgr');
select public.report_pending_kot(:F) as kot, public.report_pending_bills(:F) as pb, public.report_bills_detail(:F) as bd, public.report_void_bills(:F) as vb,
       public.report_settlement(:F) as st, public.report_sales_day_book(:F) as db, public.report_sales_month_book(:F) as mb, public.report_tax(:F) as tx, public.sales_report(:F) as sr \gset
reset role;
select t.same('4.1 Maya (flag forced on, current outlet forced to B): every report is outlet A only',
  jsonb_build_object('kot', t.names(:'kot'::jsonb -> 'rows', 'outlet_name'), 'pb', t.names(:'pb'::jsonb -> 'rows', 'outlet_name'), 'bd', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'bd'::jsonb -> 'rows') e),
     'vb', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'vb'::jsonb -> 'rows') e), 'st', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'st'::jsonb -> 'by_outlet') e),
     'tx', (select jsonb_agg(distinct e ->> 'outlet_name') from jsonb_array_elements(:'tx'::jsonb -> 'by_outlet') e),
     'db', :'db'::jsonb #> '{totals,grand_total}', 'mb', :'mb'::jsonb #> '{totals,grand_total}'),
  '{"kot":["Outlet A","Outlet A"],"pb":["Outlet A","Outlet A","Outlet A","Outlet A","Outlet A"],"bd":["Outlet A"],"vb":["Outlet A"],"st":["Outlet A"],"tx":["Outlet A"],"db":1730,"mb":1730}');
select t.recon('4.2 [Maya, restricted]', :'sr'::jsonb, :'bd'::jsonb, :'db'::jsonb, :'st'::jsonb, :'vb'::jsonb, :'tx'::jsonb, :'pb'::jsonb, 0);
update public.users set all_outlets = false, current_branch_id = null where id = t.id('mgr');
-- Carl: sales right only, restricted to A. The three operational reports work, the five money reports refuse him.
update public.users set all_outlets = true, current_branch_id = t.id('outB') where id = t.id('carl');
select t.as_('carl');
select public.report_pending_kot(:F) as kot, public.report_pending_bills(:F) as pb, public.report_void_bills(:F) as vb \gset
reset role;
select t.same('4.3 Carl (all-outlets flag forced on, current outlet forced to B): pending KOT, pending bills, void bills = outlet A only',
  jsonb_build_object('kot', t.names(:'kot'::jsonb -> 'rows', 'ticket_number'), 'pb', t.names(:'pb'::jsonb -> 'rows', 'bill_number'), 'vb', t.names(:'vb'::jsonb -> 'rows', 'bill_number')),
  '{"kot":["K-K16B","K-K14A"],"pb":["O12","O13","O16","O14","O15"],"vb":["O4","O4B"]}');
select t.as_('carl');
select t.err('4.4 Carl cannot choose All outlets', format('select public.set_current_outlet(%L, true)', t.id('outA')), 'Only the owner can see all outlets together');
reset role;
update public.users set all_outlets = false, current_branch_id = null where id = t.id('carl');

-- ---------------------------------------------------------------- 5. PERMISSIONS
select t.as_('carl');
select t.err('5.1 Carl (sales only) may use ' || f, format('select public.%I(%s)', f, :'F'), 'NO ERROR') from unnest(array['report_pending_kot','report_pending_bills','report_void_bills']) f;
select t.err('5.2 Carl (sales only) refused the money report ' || f, format('select public.%I(%s)', f, :'F'), 'You do not have the right to see financial reports.')
  from unnest(array['report_bills_detail','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
select t.as_('nina');
select t.err('5.3 Nina (no report rights) refused ' || f, format('select public.%I(%s)', f, :'F'), 'report.view_sales')
  from unnest(array['report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
select t.as_('mgr');
select t.err('5.4 Maya (sales + financial) allowed ' || f, format('select public.%I(%s)', f, :'F'), 'NO ERROR')
  from unnest(array['report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
select set_config('request.jwt.claim.sub', '', false);
select t.err('5.5 signed in as nobody: refused ' || f, format('select public.%I(%s)', f, :'F'), 'not signed in')
  from unnest(array['report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
reset role;
set role anon;
select t.err('5.6 the anon role has no execute right on ' || f, format('select public.%I(%s)', f, :'F'), 'permission denied')
  from unnest(array['report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
reset role;
select t.eq('5.7 grants: authenticated can execute, anon and public cannot (8 functions)',
  (select jsonb_build_object('n', count(*), 'auth', bool_and(has_function_privilege('authenticated', p.oid, 'execute')), 'anon', bool_or(has_function_privilege('anon', p.oid, 'execute')),
          'public', bool_or(exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0)))
     from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax')),
  '{"n":8,"auth":true,"anon":false,"public":false}');
select t.eq('5.8 all eight are STABLE SECURITY DEFINER with a fixed search_path and no dynamic SQL (no EXECUTE statement in the function text)',
  (select jsonb_build_object('n', count(*), 'stable', bool_and(provolatile = 's'), 'definer', bool_and(prosecdef), 'path', bool_and(proconfig::text like '%search_path=public, pg_temp%'),
          'dyn', bool_or(lower(prosrc) ~ '(^|[^a-z_])execute[[:space:]]'))
     from pg_proc where pronamespace = 'public'::regnamespace and proname in ('report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax')),
  '{"n":8,"stable":true,"definer":true,"path":true,"dyn":false}');

-- ---------------------------------------------------------------- 6. DATE RANGE CHECKS and EMPTY RANGES
select t.as_('owner');
select t.err('6.1 reversed range refused: ' || f, format('select public.%I(%L, %L)', f, '2026-10-22', '2026-10-20'), 'Choose a valid date range.')
  from unnest(array['report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
select t.err('6.2 null date refused: ' || f, format('select public.%I(null, %L)', f, '2026-10-20'), 'Choose a valid date range.')
  from unnest(array['report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
select t.err('6.3 367 days refused: ' || f, format('select public.%I(%L, %L)', f, '2025-10-01', '2026-10-03'), 'Choose a range of one year or less.')
  from unnest(array['report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
select t.err('6.4 366 days allowed: ' || f, format('select public.%I(%L, %L)', f, '2025-10-01', '2026-10-02'), 'NO ERROR')
  from unnest(array['report_pending_kot','report_pending_bills','report_bills_detail','report_void_bills','report_settlement','report_sales_day_book','report_sales_month_book','report_tax']) f;
select public.report_pending_kot('2026-01-01', '2026-01-02') as kot, public.report_pending_bills('2026-01-01', '2026-01-02') as pb, public.report_bills_detail('2026-01-01', '2026-01-02') as bd,
       public.report_void_bills('2026-01-01', '2026-01-02') as vb, public.report_settlement('2026-01-01', '2026-01-02') as st, public.report_sales_day_book('2026-01-01', '2026-01-02') as db,
       public.report_sales_month_book('2026-01-01', '2026-01-02') as mb, public.report_tax('2026-01-01', '2026-01-02') as tx \gset
reset role;
select t.same('6.5 empty range: empty arrays and zero totals, never null',
  jsonb_build_object('kot', :'kot'::jsonb, 'pb', :'pb'::jsonb, 'bd', :'bd'::jsonb, 'vb', :'vb'::jsonb, 'st', :'st'::jsonb, 'db', :'db'::jsonb, 'mb', :'mb'::jsonb, 'tx', :'tx'::jsonb),
  '{"kot":{"rows":[],"totals":{"kots":0,"items":0}},
    "pb":{"rows":[],"totals":{"bills":0,"amount":0,"paid":0,"balance":0}},
    "bd":{"rows":[],"truncated":false,"row_limit":2000,"total_rows":0,"totals":{"bills":0,"subtotal":0,"discount":0,"service_charge":0,"tax":0,"rounding":0,"grand_total":0}},
    "vb":{"rows":[],"truncated":false,"row_limit":2000,"total_rows":0,"totals":{"bills":0,"amount":0}},
    "st":{"by_mode":[],"by_outlet":[],"refunds":{"count":0,"amount":0,"by_mode":[],"by_outlet":[]},"rows":[],"truncated":false,"row_limit":2000,"total_rows":0,"totals":{"payments":0,"amount":0,"rounding":0,"refunds":0,"net":0}},
    "db":{"rows":[],"totals":{"bills":0,"comp_bills":0,"gross":0,"discount":0,"service_charge":0,"tax":0,"rounding":0,"net_sales":0,"grand_total":0,"cash":0,"non_cash":0,"unpaid":0}},
    "mb":{"rows":[],"totals":{"days":0,"bills":0,"comp_bills":0,"gross":0,"discount":0,"service_charge":0,"tax":0,"rounding":0,"net_sales":0,"grand_total":0,"cash":0,"non_cash":0,"unpaid":0}},
    "tx":{"rows":[],"by_outlet":[],"totals":{"taxable":0,"tax":0,"orders_tax_total":0,"tax_included":0,"exempt_sales":0}}}');

-- ---------------------------------------------------------------- 7. OTHER RESTAURANT never leaks, and cannot see ours
update public.users set all_outlets = true, current_branch_id = t.id('outC') where id = t.id('other');
select t.as_('other');
select public.report_pending_kot(:F) as kot, public.report_pending_bills(:F) as pb, public.report_bills_detail(:F) as bd, public.report_settlement(:F) as st,
       public.report_void_bills(:F) as vb, public.report_tax(:F) as tx \gset
reset role;
select t.same('7.1 the other restaurant sees only its own: KOT k19, bill o19 open, bill o11, cash payment 90, no voids, no tax',
  jsonb_build_object('kot', t.names(:'kot'::jsonb -> 'rows', 'ticket_number'), 'pb', t.names(:'pb'::jsonb -> 'rows', 'bill_number'), 'bd', t.names(:'bd'::jsonb -> 'rows', 'bill_number'),
                     'st', :'st'::jsonb -> 'totals', 'vb', :'vb'::jsonb -> 'rows', 'tx', :'tx'::jsonb -> 'rows'),
  '{"kot":["K-K19"],"pb":["O19"],"bd":["O11"],"st":{"payments":1,"amount":90,"rounding":0,"refunds":0,"net":90},"vb":[],"tx":[]}');

-- ---------------------------------------------------------------- 8. ROW CAP 2000 and totals over ALL rows (March 2026: 2105 completed bills of 10, 2003 voided bills of 5)
update public.users set all_outlets = true, current_branch_id = t.id('outA') where id = t.id('owner');
select t.as_('owner');
select public.report_bills_detail('2026-03-01', '2026-03-31') as bd, public.report_settlement('2026-03-01', '2026-03-31') as st, public.report_void_bills('2026-03-01', '2026-03-31') as vb,
       public.report_sales_day_book('2026-03-01', '2026-03-31') as db, public.sales_report('2026-03-01', '2026-03-31') as sr,
       public.report_sales_month_book('2026-03-01', '2026-10-22') as mb \gset
reset role;
select t.same('8.1 bills detail: 2000 rows returned, truncated true, total_rows 2105, totals over ALL 2105 (21050)',
  jsonb_build_object('rows', jsonb_array_length(:'bd'::jsonb -> 'rows'), 'tr', :'bd'::jsonb -> 'truncated', 'n', :'bd'::jsonb -> 'total_rows', 'tot', :'bd'::jsonb -> 'totals',
                     'first', :'bd'::jsonb #>> '{rows,0,bill_number}', 'last', :'bd'::jsonb #>> '{rows,1999,bill_number}'),
  '{"rows":2000,"tr":true,"n":2105,"tot":{"bills":2105,"subtotal":21050,"discount":0,"service_charge":0,"tax":0,"rounding":0,"grand_total":21050},"first":"BULK1","last":"BULK2000"}');
select t.same('8.2 settlement detail: 2000 rows, truncated true, totals over all 2105 payments; by_mode Cash 2105 / 21050',
  jsonb_build_object('rows', jsonb_array_length(:'st'::jsonb -> 'rows'), 'tr', :'st'::jsonb -> 'truncated', 'n', :'st'::jsonb -> 'total_rows', 'tot', :'st'::jsonb -> 'totals', 'mode', t.pick(:'st'::jsonb -> 'by_mode', array['method','payments','bills','amount'])),
  '{"rows":2000,"tr":true,"n":2105,"tot":{"payments":2105,"amount":21050,"rounding":0,"refunds":0,"net":21050},"mode":[["Cash",2105,2105,21050]]}');
select t.same('8.3 void bills: 2000 rows, truncated true, total_rows 2003, totals over all (10015)',
  jsonb_build_object('rows', jsonb_array_length(:'vb'::jsonb -> 'rows'), 'tr', :'vb'::jsonb -> 'truncated', 'n', :'vb'::jsonb -> 'total_rows', 'tot', :'vb'::jsonb -> 'totals'),
  '{"rows":2000,"tr":true,"n":2003,"tot":{"bills":2003,"amount":10015}}');
select t.same('8.4 the totals still equal sales_report on the same month (grand total, bills, voided, payments by method)',
  jsonb_build_object('gt', :'db'::jsonb #> '{totals,grand_total}', 'bills', :'db'::jsonb #> '{totals,bills}'),
  jsonb_build_object('gt', :'sr'::jsonb #> '{summary,total_billed}', 'bills', :'sr'::jsonb #> '{summary,bills}')::text);
select t.same('8.5 month book across months (1 Mar - 22 Oct): 2026-03 (1 day, 2105 bills, 21050), 2026-04 (the two cap-edge days, 4001 bills of 1) and 2026-10 (4 days with sales: 19, 20, 21, 22 Oct; 9 bills incl. o5 of the 19th, grand 3728)',
  t.pick(:'mb'::jsonb -> 'rows', array['month','days','bills','comp_bills','grand_total','cash','non_cash']),
  '[["2026-03",1,2105,0,21050,21050,0],["2026-04",2,4001,0,4001,0,0],["2026-10",4,9,1,3728,1450,1058]]');
select t.as_('owner');
select public.report_bills_detail('2026-04-05', '2026-04-05') as e1, public.report_bills_detail('2026-04-06', '2026-04-06') as e2 \gset
reset role;
select t.same('8.6 the edge of the cap: exactly 2000 bills -> 2000 rows, truncated false; 2001 bills -> 2000 rows, truncated true, total_rows 2001, totals count 2001',
  jsonb_build_object('a', jsonb_build_array(jsonb_array_length(:'e1'::jsonb -> 'rows'), :'e1'::jsonb -> 'truncated', :'e1'::jsonb #> '{totals,bills}'),
                     'b', jsonb_build_array(jsonb_array_length(:'e2'::jsonb -> 'rows'), :'e2'::jsonb -> 'truncated', :'e2'::jsonb -> 'total_rows', :'e2'::jsonb #> '{totals,grand_total}')),
  '{"a":[2000,false,2000],"b":[2000,true,2001,2001]}');

-- ---------------------------------------------------------------- 9. nothing was written, no temp tables left behind
select t.eq('9.1 no report function left a temp table behind', (select to_jsonb(count(*)) from pg_class where relname like '\_rep\_%' and relpersistence = 't'), '0');

-- ---------------------------------------------------------------- result
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
select case when :failed > 0 then 1/0 end as stop_if_failed;
