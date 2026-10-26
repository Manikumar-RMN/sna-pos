-- t149.sql: proves migration 149 (floor_status: billed_bills + billed_at, the blue "bill printed" table colour).
-- Runs on a database with migrations 001..148 + 149 applied. Self-contained: builds its own restaurant, roles, tables and bills. Test databases only.
\set ON_ERROR_STOP off
\pset pager off
\o /dev/null
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
create table t.ctx (k text primary key, v text);
grant usage on schema t to public; grant all on all tables in schema t to public; grant usage on all sequences in schema t to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t149:' || p)::uuid $$;
create function t.ctx(p text) returns uuid language sql stable as $$ select v::uuid from t.ctx where k = p $$;
create function t.as_(p text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', t.id('auth:' || p)::text, false); perform set_config('role', 'authenticated', false); end $$;
create function t.su() returns void language plpgsql as $$ begin perform set_config('role', 'postgres', false); end $$;
create function t.eq(p_label text, p_actual jsonb, p_expected jsonb) returns void language plpgsql as $$
begin insert into t.res(ok, label, detail) values (p_actual is not distinct from p_expected, p_label,
  case when p_actual is not distinct from p_expected then null else 'expected ' || p_expected::text || E'\n   got      ' || coalesce(p_actual::text, 'NULL') end); end $$;
create function t.ok(p_label text, p_cond boolean, p_detail text default null) returns void language plpgsql as $$
begin insert into t.res(ok, label, detail) values (coalesce(p_cond, false), p_label, case when coalesce(p_cond, false) then null else p_detail end); end $$;
create function t.err(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
declare m text;
begin
  begin execute p_sql; m := 'NO ERROR'; exception when others then m := sqlerrm; end;
  insert into t.res(ok, label, detail) values (position(p_expect in m) > 0, p_label, case when position(p_expect in m) > 0 then null else 'expected error containing [' || p_expect || '] got [' || m || ']' end);
end $$;
-- one floor row as jsonb, as a given person (the app calls floor_status as a signed-in user)
create function t.row_(p_who text, p_table text) returns jsonb language plpgsql as $$
declare j jsonb;
begin
  perform t.as_(p_who);
  select to_jsonb(f) into j from public.floor_status() f where f.table_number = p_table;
  perform t.su();
  return j;
end $$;
create function t.bill(p_table text) returns uuid language plpgsql as $$
declare v jsonb;
begin
  perform t.as_('owner');
  v := public.create_order(jsonb_build_array(jsonb_build_object('product_id', t.id('dosa'), 'qty', 1)), 'dine_in', t.id(p_table));
  perform t.su();
  return (v->>'order_id')::uuid;
end $$;

-- ---------------------------------------------------------------- fixtures
do $$
declare r uuid; b uuid; cat uuid; gst5 uuid; role_chef uuid; role_cash uuid;
begin
  insert into auth.users (id, email) values (t.id('auth:owner'), 'owner@t149.test'), (t.id('auth:chef'), 'chef@t149.test'), (t.id('auth:cash'), 'cash@t149.test'), (t.id('auth:other'), 'other@t149.test');
  perform set_config('request.jwt.claim.sub', t.id('auth:owner')::text, false);
  r := public.create_restaurant_with_owner('T149 Foods Pvt Ltd', 'T149 Kitchen', 'IN', 'Owner T', 'Main', 'MN');
  select id into b from public.branches where restaurant_id = r;
  select id into role_chef from public.roles where restaurant_id = r and name = 'Chef';
  select id into role_cash from public.roles where restaurant_id = r and name = 'Cashier';
  insert into public.users (restaurant_id, auth_user_id, employee_code, full_name, role_id, email) values
    (r, t.id('auth:chef'), 'EMP2', 'Charlie Chef', role_chef, 'chef@t149.test'),
    (r, t.id('auth:cash'), 'EMP3', 'Cathy Cashier', role_cash, 'cash@t149.test');
  insert into public.user_branches (user_id, branch_id, restaurant_id) select u.id, b, r from public.users u where u.restaurant_id = r and u.auth_user_id <> t.id('auth:owner');
  update public.users set all_outlets = true, current_branch_id = b where auth_user_id = t.id('auth:owner');
  insert into t.ctx values ('r', r::text), ('b', b::text);
  select id into gst5 from public.tax_groups where restaurant_id = r and name ~ '5\s*%' and name !~ '12|18' limit 1;
  insert into public.categories (restaurant_id, name, display_order) values (r, 'Mains', 1) returning id into cat;
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values (t.id('dosa'), r, cat, gst5, 'Masala Dosa', 120);
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats) values
    (t.id('A1'), r, b, 'A1', 4), (t.id('A2'), r, b, 'A2', 4), (t.id('A3'), r, b, 'A3', 4), (t.id('A4'), r, b, 'A4', 4), (t.id('A5'), r, b, 'A5', 4), (t.id('A6'), r, b, 'A6', 4);
  insert into t.ctx select 'pmCash', id::text from public.payment_methods where restaurant_id = r and kind = 'cash' and is_active order by display_order limit 1;
  perform set_config('request.jwt.claim.sub', t.id('auth:other')::text, false);
  r := public.create_restaurant_with_owner('T149 Other Pvt Ltd', 'T149 Other', 'IN', 'Other Owner', 'Main', 'MN');
end $$;
reset role;

-- ---------------------------------------------------------------- 1. columns
select t.eq('1.1 the 16 old columns keep name and order; billed_bills and billed_at are the two new last ones',
  (select jsonb_agg(c order by o) from unnest((select proargnames from pg_proc where oid = 'public.floor_status()'::regprocedure)) with ordinality x(c, o)),
  '["table_id","table_number","seats","open_bills","open_total","oldest_open_at","kot_waiting","oldest_kot_at","reservation_id","reservation_at","reservation_name","reservation_party","db_now","kot_due_at","kot_prep_min","kot_ticket_at","billed_bills","billed_at"]'::jsonb);
select t.row_('owner', 'A1') as r_a1 \gset
select t.eq('1.2 free table before any bill: open_bills 0, billed_bills 0, billed_at null',
  jsonb_build_array(:'r_a1'::jsonb->'open_bills', :'r_a1'::jsonb->'billed_bills', :'r_a1'::jsonb->'billed_at'), '[0, 0, null]'::jsonb);
select t.eq('1.3 the two new columns are integer and timestamptz',
  (select jsonb_agg(format_type(ty, null) order by o) from (select ty, o from unnest((select proallargtypes from pg_proc where oid = 'public.floor_status()'::regprocedure)) with ordinality x(ty, o) order by o desc limit 2) z),
  '["integer", "timestamp with time zone"]'::jsonb);

-- ---------------------------------------------------------------- 2. the colour cases
select t.bill('A2') as a2b1 \gset
select t.row_('owner', 'A2') as r_a2_unprinted \gset
select t.eq('2.1 open bill, no print: open_bills 1, billed_bills 0, billed_at null',
  jsonb_build_array(:'r_a2_unprinted'::jsonb->'open_bills', :'r_a2_unprinted'::jsonb->'billed_bills', :'r_a2_unprinted'::jsonb->'billed_at'), '[1, 0, null]'::jsonb);

select t.as_('owner');
select public.log_print('bill', :'a2b1'::uuid) as lp1 \gset
select t.su();
select t.eq('2.2 the first print wrote bill.print', (:'lp1'::jsonb)->'action', '"bill.print"'::jsonb);
select t.row_('owner', 'A2') as r_a2_printed \gset
select t.eq('2.3 after log_print bill: open_bills 1, billed_bills 1',
  jsonb_build_array(:'r_a2_printed'::jsonb->'open_bills', :'r_a2_printed'::jsonb->'billed_bills'), '[1, 1]'::jsonb);
select t.ok('2.4 billed_at is set and equals the audit row time of the print',
  (:'r_a2_printed'::jsonb->>'billed_at') is not null
  and (:'r_a2_printed'::jsonb->>'billed_at')::timestamptz = (select min(created_at) from public.audit_logs where entity_type = 'orders' and entity_id = :'a2b1'::uuid and action = 'bill.print'));

-- a reprint does not make it count twice, and billed_at stays the first print
select t.as_('owner');
select public.log_print('bill', :'a2b1'::uuid, null, true) as lp2 \gset
select t.su();
select t.row_('owner', 'A2') as r_a2_reprinted \gset
select t.eq('2.5 a reprint of the same bill: still billed_bills 1, billed_at unchanged (first print)',
  jsonb_build_array(:'r_a2_reprinted'::jsonb->'billed_bills', :'r_a2_reprinted'::jsonb->>'billed_at' = :'r_a2_printed'::jsonb->>'billed_at'), '[1, true]'::jsonb);

-- a second open bill on the same table, not printed
select t.bill('A2') as a2b2 \gset
select t.row_('owner', 'A2') as r_a2_two \gset
select t.eq('2.6 second open bill unprinted: open_bills 2, billed_bills 1, billed_at still the first print',
  jsonb_build_array(:'r_a2_two'::jsonb->'open_bills', :'r_a2_two'::jsonb->'billed_bills', :'r_a2_two'::jsonb->>'billed_at' = :'r_a2_printed'::jsonb->>'billed_at'), '[2, 1, true]'::jsonb);

-- print the second one later: two billed, billed_at = the OLDEST print
select pg_sleep(0.05);
select t.as_('owner');
select public.log_print('bill', :'a2b2'::uuid) as lp3 \gset
select t.su();
select t.row_('owner', 'A2') as r_a2_both \gset
select t.eq('2.7 both printed: billed_bills 2, billed_at is still the oldest print',
  jsonb_build_array(:'r_a2_both'::jsonb->'billed_bills', :'r_a2_both'::jsonb->>'billed_at' = :'r_a2_printed'::jsonb->>'billed_at'), '[2, true]'::jsonb);

-- paid: the table is free again
select t.as_('owner');
select public.pay_order(:'a2b1'::uuid, t.ctx('pmCash'), 100000, null) as pay1 \gset
select public.pay_order(:'a2b2'::uuid, t.ctx('pmCash'), 100000, null) as pay2 \gset
select t.su();
select t.row_('owner', 'A2') as r_a2_paid \gset
select t.eq('2.8 both bills paid: open_bills 0, billed_bills 0, billed_at null (table free again)',
  jsonb_build_array(:'r_a2_paid'::jsonb->'open_bills', :'r_a2_paid'::jsonb->'billed_bills', :'r_a2_paid'::jsonb->'billed_at'), '[0, 0, null]'::jsonb);
select t.ok('2.8b the paid bills really are paid', (select bool_and(payment_status = 'paid') from public.orders where id in (:'a2b1'::uuid, :'a2b2'::uuid)));

-- one paid, one printed-and-open: only the open one counts
select t.bill('A3') as a3b1 \gset
select t.bill('A3') as a3b2 \gset
select t.as_('owner');
select public.log_print('bill', :'a3b1'::uuid) as x1 \gset
select public.log_print('bill', :'a3b2'::uuid) as x2 \gset
select public.pay_order(:'a3b1'::uuid, t.ctx('pmCash'), 100000, null) as x3 \gset
select t.su();
select t.row_('owner', 'A3') as r_a3 \gset
select t.eq('2.9 one printed bill paid, the other printed and open: open_bills 1, billed_bills 1 (the paid one no longer counts)',
  jsonb_build_array(:'r_a3'::jsonb->'open_bills', :'r_a3'::jsonb->'billed_bills'), '[1, 1]'::jsonb);

-- voided: not counted even if it was printed
select t.bill('A4') as a4b1 \gset
select t.as_('owner');
select public.log_print('bill', :'a4b1'::uuid) as y1 \gset
select public.void_order(:'a4b1'::uuid, 'test void') as y2 \gset
select t.su();
select t.row_('owner', 'A4') as r_a4 \gset
select t.eq('2.10 a printed bill that was voided is not counted: open_bills 0, billed_bills 0, billed_at null',
  jsonb_build_array(:'r_a4'::jsonb->'open_bills', :'r_a4'::jsonb->'billed_bills', :'r_a4'::jsonb->'billed_at'), '[0, 0, null]'::jsonb);

-- kot print does not make a bill billed
select t.bill('A5') as a5b1 \gset
select t.as_('owner');
select public.send_to_kitchen(:'a5b1'::uuid) as z0 \gset
select public.log_print('kot', :'a5b1'::uuid) as z1 \gset
select t.su();
select t.row_('owner', 'A5') as r_a5 \gset
select t.eq('2.11 a kitchen ticket reprint (kot.reprint) does not count as a printed bill',
  jsonb_build_array(:'r_a5'::jsonb->'open_bills', :'r_a5'::jsonb->'billed_bills', :'r_a5'::jsonb->'billed_at'), '[1, 0, null]'::jsonb);

-- an unpaid, printed bill on the other restaurant's side never leaks: other restaurant sees none of our tables
select t.as_('other');
select count(*) as n_other from public.floor_status() \gset
select t.su();
select t.eq('2.12 the other restaurant sees none of our tables', to_jsonb(:n_other::int), '0'::jsonb);

-- ---------------------------------------------------------------- 3. old columns unchanged
select t.row_('owner', 'A5') as r_a5b \gset
select t.eq('3.1 old columns on A5 as before: open_bills 1, open_total = the bill total, kot_waiting 1, reservation empty',
  jsonb_build_array(:'r_a5b'::jsonb->'open_bills', (:'r_a5b'::jsonb->>'open_total')::numeric = (select grand_total from public.orders where id = :'a5b1'::uuid),
                    :'r_a5b'::jsonb->'kot_waiting', :'r_a5b'::jsonb->'reservation_id'), '[1, true, 1, null]'::jsonb);
select t.eq('3.2 oldest_open_at is the bill time, db_now is the database clock',
  jsonb_build_array((:'r_a5b'::jsonb->>'oldest_open_at')::timestamptz = (select coalesce(client_created_at, created_at) from public.orders where id = :'a5b1'::uuid),
                    (:'r_a5b'::jsonb->>'db_now')::timestamptz between now() - interval '1 minute' and now() + interval '1 minute'), '[true, true]'::jsonb);
select t.eq('3.3 kot_due_at / kot_prep_min / kot_ticket_at still filled for the waiting ticket',
  jsonb_build_array(:'r_a5b'::jsonb->>'kot_due_at' is not null, :'r_a5b'::jsonb->>'kot_ticket_at' is not null, :'r_a5b'::jsonb->'kot_prep_min'), '[true, true, null]'::jsonb);
select t.as_('owner');
select jsonb_agg(table_number order by ord) as order_a from (select table_number, row_number() over () as ord from public.floor_status()) z \gset
select t.su();
select t.eq('3.4 only active tables of this outlet, in table order (A1..A6)', :'order_a'::jsonb, '["A1","A2","A3","A4","A5","A6"]'::jsonb);
select t.ok('3.5 floor_status is security definer with a fixed search_path',
  (select prosecdef and proconfig is not null from pg_proc where oid = 'public.floor_status()'::regprocedure));

-- ---------------------------------------------------------------- 4. permissions as in t132-134 F15/F16/F19/F20
select t.err('4.1 (F15) a role without order.create is refused', $q$select t.as_('chef'); select * from public.floor_status()$q$, 'order.create'); select t.su();
select t.err('4.2 (F16) not signed in is refused', $q$select set_config('request.jwt.claim.sub', '', false); select set_config('role', 'authenticated', false); select * from public.floor_status()$q$, 'not signed in'); select t.su();
select t.as_('cash');
select count(*) as n_cash from public.floor_status() \gset
select t.su();
select t.eq('4.3 a Cashier (order.create) still sees all 6 tables', to_jsonb(:n_cash::int), '6'::jsonb);
select t.su();
select t.ok('4.4 (F19) floor_status is read only (stable)', (select provolatile from pg_proc where proname = 'floor_status') = 's');
select t.ok('4.5 (F20) not callable by anon or public; callable by authenticated and service_role',
  not has_function_privilege('anon', 'public.floor_status()', 'execute') and has_function_privilege('authenticated', 'public.floor_status()', 'execute')
  and has_function_privilege('service_role', 'public.floor_status()', 'execute')
  and not exists (select 1 from information_schema.routine_privileges where specific_schema = 'public' and routine_name = 'floor_status' and grantee = 'PUBLIC'));
select t.ok('4.6 only one floor_status function exists (the old 16-column one was dropped)', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'floor_status') = 1);

-- result
\o
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
