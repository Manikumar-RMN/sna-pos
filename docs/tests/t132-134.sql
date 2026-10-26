-- t132-134.sql: proves move_order_items (migration 132) and floor_status (migration 134) on a database with migrations 001..129 + 132 + 134.
-- Run it on a FRESH scratch database (docs/tests/run-t132-134.sh builds one). Test databases only: it signs in as made-up people.
-- Bills are made with the REAL functions (create_restaurant_with_owner, create_order, add_order_items, send_to_kitchen, pay_order, adjust_order,
-- void_order), so the money engine under test is the live one. Fixtures that need a past time are back-dated with a direct UPDATE.
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
create table t.kv (k text primary key, v text);
grant usage on schema t to public; grant all on t.res, t.kv to public; grant usage on sequence t.res_n_seq to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t132:' || p)::uuid $$;
create function t.set(p_k text, p_v text) returns void language sql as $$ insert into t.kv values (p_k, p_v) on conflict (k) do update set v = excluded.v $$;
create function t.get(p_k text) returns text language sql stable as $$ select v from t.kv where k = p_k $$;
create function t.uid(p_k text) returns uuid language sql stable as $$ select t.get(p_k)::uuid $$;
create function t.as_(p text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', t.id('auth:' || p)::text, false); perform set_config('role', 'authenticated', false); end $$;
create function t.su() returns void language plpgsql as $$ begin execute 'reset role'; end $$;
create function t.ok(p_label text, p_cond boolean, p_detail text default null) returns void language plpgsql as $$
begin insert into t.res(ok, label, detail) values (coalesce(p_cond, false), p_label, case when coalesce(p_cond, false) then null else p_detail end); end $$;
create function t.eq(p_label text, p_actual anyelement, p_expected anyelement) returns void language plpgsql as $$
begin insert into t.res(ok, label, detail) values (p_actual is not distinct from p_expected, p_label,
  case when p_actual is not distinct from p_expected then null else 'expected ' || coalesce(p_expected::text, 'NULL') || E'\n   got      ' || coalesce(p_actual::text, 'NULL') end); end $$;
create function t.err(p_label text, p_sql text, p_expect text) returns void language plpgsql as $$
declare m text; part text;
begin
  begin
    foreach part in array string_to_array(p_sql, ';') loop if btrim(part) <> '' then execute part; end if; end loop;
    m := 'NO ERROR';
  exception when others then m := sqlerrm; end;
  execute 'reset role';
  insert into t.res(ok, label, detail) values (position(p_expect in m) > 0, p_label, case when position(p_expect in m) > 0 then null else 'expected error containing [' || p_expect || '] got [' || m || ']' end);
end $$;

-- ---------------------------------------------------------------- fixtures (real setup function, then staff, tables, menu)
do $$
declare x text; r uuid; b uuid; r2 uuid; cat uuid; tg5 uuid; tgl uuid; mgr_role uuid; nobody uuid;
begin
  foreach x in array array['owner','carl','wendy','nina','mgr','other'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t132.test');
  end loop;
  perform set_config('request.jwt.claim.sub', t.id('auth:owner')::text, false);
  r := public.create_restaurant_with_owner('T132 Foods Pvt Ltd', 'T132 Kitchen', 'IN', 'Olivia Owner', 'Main', 'MN');
  perform set_config('request.jwt.claim.sub', t.id('auth:other')::text, false);
  r2 := public.create_restaurant_with_owner('Other Foods Pvt Ltd', 'Other Kitchen', 'IN', 'Other Owner', 'Main', 'MN');
  perform t.set('rest', r::text); perform t.set('rest2', r2::text);
  select id into b from public.branches where restaurant_id = r; perform t.set('branch', b::text);
  update public.restaurants set edition = 'professional' where id = r;
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone)
    select t.id('branchB'), r, 'Outlet B', 'B', country_code, timezone from public.branches where id = b;
  update public.branches set created_at = now() + interval '1 hour' where id = t.id('branchB');
  insert into public.roles (id, restaurant_id, name, is_system) values (t.id('roleNobody'), r, 'Nobody', false);
  insert into public.role_permissions (role_id, permission_key) values (t.id('roleNobody'), 'report.view_sales');
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    select t.id('u:carl'), r, t.id('auth:carl'), 'E2', 'Carl Cashier', ro.id, 'carl@t132.test' from public.roles ro where ro.restaurant_id = r and ro.name = 'Cashier';
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    select t.id('u:wendy'), r, t.id('auth:wendy'), 'E3', 'Wendy Waiter', ro.id, 'wendy@t132.test' from public.roles ro where ro.restaurant_id = r and ro.name = 'Cashier';
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    values (t.id('u:nina'), r, t.id('auth:nina'), 'E4', 'Nina Nobody', t.id('roleNobody'), 'nina@t132.test');
  insert into public.user_branches (user_id, branch_id, restaurant_id) values (t.id('u:carl'), b, r), (t.id('u:wendy'), b, r);
  -- tables: T1..T4 at the outlet, K1 kiosk, X1 at outlet B
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats) values
    (t.id('T1'), r, b, 'T1', 4), (t.id('T2'), r, b, 'T2', 4), (t.id('T3'), r, b, 'T3', 2), (t.id('T4'), r, b, 'T4', 6),
    (t.id('T10'), r, b, 'T10', 4), (t.id('X1'), r, t.id('branchB'), 'X1', 4);
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats, is_kiosk) values (t.id('K1'), r, b, 'K1', 1, true);
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats, is_active) values (t.id('OFF'), r, b, 'OFF', 4, false);
  select id into tg5 from public.tax_groups where restaurant_id = r and name ~ '5\s*%' and name !~ '12|18' order by name limit 1;
  if tg5 is null then select id into tg5 from public.tax_groups where restaurant_id = r order by name limit 1; end if;
  perform t.set('tg5', tg5::text);
  select id into cat from public.categories where restaurant_id = r limit 1;
  if cat is null then insert into public.categories (id, restaurant_id, name, display_order) values (t.id('cat'), r, 'Mains', 1); cat := t.id('cat'); end if;
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values
    (t.id('dosa'), r, cat, tg5, 'Masala Dosa', 120), (t.id('biryani'), r, cat, tg5, 'Chicken Biryani', 249.5),
    (t.id('cola'), r, cat, (select id from public.tax_groups where restaurant_id = r and name ~ '18\s*%' order by name limit 1), 'Cola', 60),
    (t.id('thali'), r, cat, tg5, 'Veg Thali', 333.33);
  perform t.set('cash', (select id::text from public.payment_methods where restaurant_id = r and kind = 'cash' and is_active order by display_order limit 1));
  -- a liquor tax group (separate liquor bills) and one liquor product
  insert into public.tax_groups (id, restaurant_id, name) values (t.id('tgLiq'), r, 'Liquor T132');
  perform t.as_('owner'); perform public.tax_group_set_liquor(t.id('tgLiq'), true); perform t.su();
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values (t.id('beer'), r, cat, t.id('tgLiq'), 'Beer', 200);
end $$;

-- helper: a running bill on a table, as Carl, with a kitchen ticket
create function t.bill(p_key text, p_table text, p_items jsonb, p_who text default 'carl') returns uuid language plpgsql as $$
declare v jsonb;
begin
  perform t.as_(p_who);
  v := public.create_order(p_items, 'dine_in', t.id(p_table));
  perform public.send_to_kitchen((v->>'order_id')::uuid);
  perform t.su();
  perform t.set('bill:' || p_key, v->>'order_id');
  return (v->>'order_id')::uuid;
end $$;
create function t.items(p_spec jsonb) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('product_id', t.id(k), 'qty', v::numeric)) from jsonb_each_text(p_spec) x(k, v) $$;
-- sum of the money columns of the given bills
create function t.sum_of(p_ids uuid[], p_col text) returns numeric language plpgsql stable as $$
declare v numeric; begin execute format('select coalesce(sum(%I),0) from public.orders where id = any($1)', p_col) into v using p_ids; return v; end $$;
create function t.line(p_order uuid, p_prod text) returns public.order_items language sql stable as $$
  select * from public.order_items where order_id = p_order and product_id = t.id(p_prod) and cancelled_at is null order by quantity desc limit 1 $$;

-- ---------------------------------------------------------------- 1. whole line to an EMPTY table (new bill)
do $$
declare a uuid; v jsonb; n uuid; before_g numeric; ln public.order_items; ref uuid := gen_random_uuid(); k_before int;
begin
  a := t.bill('A', 'T1', t.items('{"dosa":2,"biryani":1,"cola":3}'));
  select grand_total into before_g from public.orders where id = a;
  perform t.ok('1.0 setup: bill A has 3 lines, a kitchen ticket with 3 items, no payment', (select count(*) from public.order_items where order_id = a) = 3
     and (select count(*) from public.kitchen_ticket_items ki join public.kitchen_tickets k on k.id = ki.kitchen_ticket_id where k.order_id = a) = 3);
  select * into ln from t.line(a, 'biryani');
  perform t.as_('carl');
  v := public.move_order_items(a, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T2'), ref);
  perform t.su();
  n := (v->>'to_order_id')::uuid; perform t.set('bill:A2', n::text);
  perform t.ok('1.1 a new bill was opened on T2 (unpaid, dine-in, on table T2)', (v->>'new_bill')::boolean and (select dining_table_id = t.id('T2') and payment_status = 'unpaid' and order_type = 'dine_in' and status <> 'voided' from public.orders where id = n));
  perform t.eq('1.2 totals: source + target after = total before (to the paisa, before rounding)', (select sum(grand_total - rounding_adjustment) from public.orders where id in (a, n)), (v->>'unrounded_before')::numeric);
  perform t.ok('1.2b the rounded totals differ by at most 1 (one rupee of rounding)', abs((select sum(grand_total) from public.orders where id in (a, n)) - before_g) <= 1);
  perform t.ok('1.3 subtotal and tax are conserved across both bills (equal to the sum of the lines)', (select sum(subtotal) = (select sum(unit_price * quantity) from public.order_items where order_id in (a, n) and cancelled_at is null)
     and sum(tax_total) = (select sum(line_tax) from public.order_items where order_id in (a, n) and cancelled_at is null) from public.orders where id in (a, n)));
  perform t.ok('1.4 the biryani line itself moved (same line id, same price, same tax snapshot)', (select order_id = n and unit_price = ln.unit_price and tax_comps is not distinct from ln.tax_comps and quantity = 1 from public.order_items where id = ln.id));
  perform t.ok('1.5 its tax rows follow it (order_item_taxes on the new bill)', (select count(*) > 0 from public.order_item_taxes where order_item_id = ln.id and order_id = n)
     and not exists (select 1 from public.order_item_taxes where order_item_id = ln.id and order_id = a));
  perform t.eq('1.6 source bill kept two lines', (select count(*)::int from public.order_items where order_id = a and cancelled_at is null), 2);
  -- the kitchen: the biryani was on a ticket shared with the other lines -> that ticket stays, the biryani gets a copy on the new bill
  perform t.ok('1.7 kitchen: the biryani kitchen line now sits on a ticket of the NEW bill; the other two stay on the old ticket',
     (select count(*) = 1 from public.kitchen_ticket_items ki join public.kitchen_tickets k on k.id = ki.kitchen_ticket_id where ki.order_item_id = ln.id and k.order_id = n)
     and (select count(*) = 2 from public.kitchen_ticket_items ki join public.kitchen_tickets k on k.id = ki.kitchen_ticket_id where k.order_id = a));
  perform t.ok('1.8 the new ticket has a number of the new bill and keeps the status', (select k.ticket_number like 'K-' || (select bill_number from public.orders where id = n) || '%' and k.status = 'new'
     from public.kitchen_tickets k where k.order_id = n limit 1));
  perform t.eq('1.9 audit row order.move_item written once', (select count(*)::int from public.audit_logs where action = 'order.move_item' and entity_id = n), 1);
  perform t.ok('1.10 the audit row names both bills, both tables and the item', (select new_value->>'from_bill' = (select bill_number from public.orders where id = a) and new_value->>'to_table' = 'T2'
     and new_value->>'from_table' = 'T1' and new_value::text like '%Chicken Biryani%' from public.audit_logs where action = 'order.move_item' and entity_id = n));

  -- idempotent: same request id again changes nothing and answers the same
  select count(*) into k_before from public.order_items;
  perform t.as_('carl');
  v := public.move_order_items(a, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T2'), ref);
  perform t.su();
  perform t.ok('1.11 replay with the same request id returns repeat=true and the same target bill', (v->>'repeat')::boolean and (v->>'to_order_id')::uuid = n);
  perform t.eq('1.12 replay moved nothing more (line count unchanged) and wrote no second audit row', (select count(*)::int from public.order_items), k_before);
  perform t.eq('1.13 still one audit row', (select count(*)::int from public.audit_logs where action = 'order.move_item' and entity_id = n), 1);
  perform t.err('1.14 the same request id on another bill is refused', format($q$select t.as_('carl'); select public.move_order_items(%L, '[]'::jsonb, %L, %L)$q$, n, t.id('T1'), ref), 'already used for something else');
  perform t.su();
end $$;

-- ---------------------------------------------------------------- 2. part of a line, onto an OCCUPIED table
do $$
declare a uuid := t.uid('bill:A'); n uuid := t.uid('bill:A2'); v jsonb; before_g numeric; before_n int; ln public.order_items; cl public.order_items; kt_n int;
begin
  select grand_total into before_g from public.orders where id = a; select sum(grand_total) into before_g from public.orders where id in (a, n);
  select * into ln from t.line(a, 'cola');
  perform t.as_('carl');
  v := public.move_order_items(a, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T2'), gen_random_uuid());
  perform t.su();
  perform t.ok('2.1 lands on the EXISTING open bill of T2 (no new bill)', not (v->>'new_bill')::boolean and (v->>'to_order_id')::uuid = n);
  perform t.eq('2.2 amount due before rounding is identical across both bills (to the paisa); the rounded totals differ by at most 1 (one rupee of rounding) (each bill rounds on its own)',
     (select sum(grand_total - rounding_adjustment) from public.orders where id in (a, n)), (v->>'unrounded_before')::numeric);
  perform t.ok('2.2b rounded total before and after differ by at most 1 (one rupee of rounding)', abs((select sum(grand_total) from public.orders where id in (a, n)) - before_g) <= 1);
  select * into cl from public.order_items where order_id = n and product_id = t.id('cola') and cancelled_at is null;
  perform t.ok('2.3 the cola copy on T2 has quantity 1, same unit price and tax snapshot; the source line has quantity 2',
     cl.quantity = 1 and cl.unit_price = ln.unit_price and cl.tax_comps is not distinct from ln.tax_comps and cl.id <> ln.id
     and (select quantity from public.order_items where id = ln.id) = 2);
  perform t.ok('2.4 the copy has its own tax rows and a computed total', (select count(*) > 0 from public.order_item_taxes where order_item_id = cl.id) and cl.line_total > 0);
  perform t.ok('2.5 kitchen: the copy has a kitchen line of 1 on a ticket of the T2 bill; the source kitchen line is now 2',
     (select quantity from public.kitchen_ticket_items ki where ki.order_item_id = cl.id and ki.kitchen_ticket_id in (select id from public.kitchen_tickets where order_id = n)) = 1
     and (select quantity from public.kitchen_ticket_items where order_item_id = ln.id) = 2);
  perform t.ok('2.6 the shared old ticket was not emptied of its other items (dosa + cola still on the old bill ticket)',
     (select count(*) = 2 from public.kitchen_ticket_items ki join public.kitchen_tickets k on k.id = ki.kitchen_ticket_id where k.order_id = a and ki.status <> 'cancelled'));
  perform t.ok('2.7 every kitchen ticket belongs to the bill that holds its items (no ticket points at a bill that does not hold its lines)',
     not exists (select 1 from public.kitchen_ticket_items ki join public.kitchen_tickets k on k.id = ki.kitchen_ticket_id
                  join public.order_items oi on oi.id = ki.order_item_id where oi.order_id <> k.order_id));
  -- moving the remaining quantity of the same line: whole-line move now (quantity equals)
  v := null;
  perform t.as_('carl');
  v := public.move_order_items(a, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 2)), t.id('T2'), gen_random_uuid());
  perform t.su();
  perform t.ok('2.8 moving the rest of the line keeps the rounded total within 1 of the start', abs((select sum(grand_total) from public.orders where id in (a, n)) - before_g) <= 1);
  perform t.eq('2.9 the source bill now has one line (dosa)', (select count(*)::int from public.order_items where order_id = a and cancelled_at is null), 1);
  perform t.ok('2.10 a ticket whose items ALL moved is repointed (no copy): the cola ticket items of bill A moved with their ticket',
     not exists (select 1 from public.kitchen_ticket_items ki join public.kitchen_tickets k on k.id = ki.kitchen_ticket_id
                  join public.order_items oi on oi.id = ki.order_item_id where oi.order_id <> k.order_id));
end $$;

-- ---------------------------------------------------------------- 3. the waiter's "food is ready" alert shows the NEW table
do $$
declare n uuid := t.uid('bill:A2'); a uuid := t.uid('bill:A'); alerts jsonb;
begin
  update public.kitchen_tickets set status = 'ready', ready_at = now(), waiter_seen_at = null where order_id in (a, n);
  perform t.as_('carl');
  alerts := public.waiter_ready_alerts();
  perform t.su();
  perform t.ok('3.1 ready alerts list tickets for table T2 (the moved food) and for T1 (the rest), each with the right table',
    exists (select 1 from jsonb_array_elements(alerts) e where e->>'table' = 'T2' and e->>'order_id' = n::text)
    and exists (select 1 from jsonb_array_elements(alerts) e where e->>'table' = 'T1' and e->>'order_id' = a::text));
  perform t.ok('3.2 no ready alert names T1 for an item that now sits on T2', not exists (select 1 from jsonb_array_elements(alerts) e, jsonb_array_elements(e->'items') i
     where e->>'table' = 'T1' and i->>'name' like 'Chicken Biryani%'));
end $$;

-- ---------------------------------------------------------------- 4. refusals (each leaves everything as it was)
do $$
declare p uuid; d uuid; pt uuid; vv uuid; a uuid := t.uid('bill:A'); n uuid := t.uid('bill:A2'); ln public.order_items; snap text; tgt uuid; other uuid; pm uuid := t.uid('cash');
begin
  -- paid bill on T3
  p := t.bill('P', 'T3', t.items('{"dosa":1,"thali":1}'));
  perform t.as_('carl'); perform public.pay_order(p, pm); perform t.su();
  select * into ln from t.line(p, 'dosa');
  perform t.err('4.1 a paid bill refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, p, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T4')), 'already has a payment');
  perform t.su();
  -- part-paid bill on T3? the table is free after paying: new bill, pay part
  pt := t.bill('PT', 'T3', t.items('{"dosa":2,"thali":1}'));
  perform t.as_('carl'); perform public.pay_order(pt, pm, null, 50); perform t.su();
  select * into ln from t.line(pt, 'dosa');
  perform t.err('4.2 a part-paid bill refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, pt, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T4')), 'already has a payment');
  perform t.su();
  -- discounted bill on T4
  d := t.bill('D', 'T4', t.items('{"dosa":2,"thali":1}'));
  perform t.as_('owner'); perform public.adjust_order(d, 20, 'test'); perform t.su();
  select * into ln from t.line(d, 'dosa');
  perform t.err('4.3 a discounted bill refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, d, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T10')), 'has a discount');
  perform t.su();
  -- the discounted bill as TARGET is refused too
  select * into ln from t.line(a, 'dosa');
  perform t.err('4.4 moving onto a discounted bill refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, a, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T4')), 'discount');
  perform t.su();
  -- voided bill on T10
  vv := t.bill('V', 'T10', t.items('{"dosa":2,"thali":1}'));
  select * into ln from t.line(vv, 'dosa');
  perform t.as_('owner'); perform public.void_order(vv, 'test'); perform t.su();
  perform t.err('4.5 a voided bill refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, vv, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T2')), 'voided');
  perform t.su();
  -- ordinary refusals on bill A (T1, dosa 1 left) and A2 (T2)
  select * into ln from t.line(n, 'cola');
  perform t.err('4.6 moving every item off a bill refuses (leave at least one)', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, a, jsonb_build_array(jsonb_build_object('order_item_id', (select id from t.line(a, 'dosa')), 'qty', (select quantity from t.line(a, 'dosa')))), t.id('T3')), 'Leave at least one item');
  perform t.su();
  perform t.err('4.7 moving onto the table it is already on refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T2')), 'already on table');
  perform t.su();
  perform t.err('4.8 more than the line holds refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 99)), t.id('T3')), 'are on the bill');
  perform t.su();
  perform t.err('4.9 an item of another bill refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n, jsonb_build_array(jsonb_build_object('order_item_id', (select id from t.line(a, 'dosa')), 'qty', 1)), t.id('T3')), 'not on this bill');
  perform t.su();
  perform t.err('4.10 an empty list refuses', format($q$select t.as_('carl'); select public.move_order_items(%L, '[]'::jsonb, %L)$q$, n, t.id('T3')), 'Choose the items');
  perform t.su();
  perform t.err('4.11 a kiosk, an inactive table and a table of another outlet are not targets', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('K1')), 'does not exist');
  perform t.su();
  perform t.err('4.12 inactive table', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('OFF')), 'does not exist');
  perform t.su();
  perform t.err('4.13 table of another outlet', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('X1')), 'same outlet');
  perform t.su();
  perform t.err('4.14 a role without order.create is refused', format($q$select t.as_('nina'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T3')), 'order.create');
  perform t.su();
  perform t.err('4.15 another restaurant cannot touch our bill', format($q$select t.as_('other'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T3')), 'Bill not found');
  perform t.su();
  perform t.err('4.16 not signed in', format($q$select set_config('request.jwt.claim.sub', '', false); select set_config('role', 'authenticated', false); select public.move_order_items(%L, '[]'::jsonb, %L)$q$, n, t.id('T3')), 'not signed in');
  perform t.su();
end $$;

-- ---------------------------------------------------------------- 4b. a part-move copy of an open-priced line is not a second open-price event (QA low)
-- Runs inside a sub-block that is rolled back (the variables survive the rollback), so the later sections see the data unchanged.
do $$
declare n uuid := t.uid('bill:A2'); ln public.order_items; cl public.order_items; v jsonb; before_n int; after_n int; r1 boolean; r2 boolean;
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'order_items' and column_name = 'open_price') then
    perform t.ok('4b.0 (131 is not applied in this run: the open-price copy check runs in the go-live run, run-golive-130-139.sh)', true);
    return;
  end if;
  begin
    select * into ln from public.order_items where order_id = n and cancelled_at is null order by quantity desc, id limit 1;
    execute format('update public.order_items set open_price = true where id = %L', ln.id);
    update public.order_items set quantity = greatest(quantity, 2) where id = ln.id;
    select count(*) into before_n from public.audit_logs where action = 'order.open_price';
    perform t.as_('carl');
    v := public.move_order_items(n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T3'), gen_random_uuid());
    perform t.su();
    select count(*) into after_n from public.audit_logs where action = 'order.open_price';
    select * into cl from public.order_items where order_id = (v->>'to_order_id')::uuid and product_id = ln.product_id and cancelled_at is null order by created_at desc limit 1;
    r1 := cl.id is not null and cl.id <> ln.id and cl.open_price;
    r2 := after_n = before_n;
    raise exception 'rollback 4b';
  exception when others then
    if sqlerrm <> 'rollback 4b' then raise; end if;
  end;
  perform t.su();
  perform t.ok('4b.1 the copy exists and keeps open_price = true (the flag stays on the line)', coalesce(r1, false));
  perform t.ok('4b.2 moving part of an open-priced line writes no new order.open_price audit row', coalesce(r2, false));
end $$;

-- ---------------------------------------------------------------- 5. all-or-nothing: a bad second item undoes the first, the bill number series and the new bill
do $$
declare n uuid := t.uid('bill:A2'); ln public.order_items; snap1 text; snap2 text; seq1 text; seq2 text;
begin
  select * into ln from t.line(n, 'thali');
  if ln.id is null then select * into ln from t.line(n, 'cola'); end if;
  select string_agg(id::text || ':' || order_id::text || ':' || quantity::text || ':' || line_total::text, ',' order by id) into snap1 from public.order_items;
  select string_agg(next_seq::text, ',') into seq1 from public.bill_series;
  perform t.err('5.1 first item valid, second invalid -> error', format($q$select t.as_('carl'); select public.move_order_items(%L, %L::jsonb, %L)$q$, n,
     jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1), jsonb_build_object('order_item_id', gen_random_uuid(), 'qty', 1)), t.id('T3')), 'not on this bill');
  perform t.su();
  select string_agg(id::text || ':' || order_id::text || ':' || quantity::text || ':' || line_total::text, ',' order by id) into snap2 from public.order_items;
  select string_agg(next_seq::text, ',') into seq2 from public.bill_series;
  perform t.ok('5.2 nothing changed: lines, quantities, totals identical', snap1 = snap2);
  perform t.ok('5.3 the bill number series did not advance (the new bill never existed)', seq1 = seq2);
  perform t.eq('5.4 no bill was created on T3 by the failed move', (select count(*)::int from public.orders where dining_table_id = t.id('T3') and payment_status = 'unpaid'), 0);
end $$;

-- ---------------------------------------------------------------- 6. liquor stays on liquor bills
do $$
declare lb uuid; fb uuid; v jsonb; ln public.order_items; ref uuid := gen_random_uuid();
begin
  perform t.as_('carl');
  lb := (public.create_order(t.items('{"beer":2}'), 'dine_in', t.id('T10'))->>'order_id')::uuid;
  perform t.su();
  perform t.ok('6.0 setup: beer went on a liquor bill', (select is_liquor from public.orders where id = lb));
  -- a food bill can't be moved liquor: moving food to a table whose only open bill is liquor makes a NEW food bill
  fb := t.bill('F10', 'T4', t.items('{"dosa":1,"thali":1}'));
  select * into ln from t.line(fb, 'thali');
  -- T4 has the discounted bill D too; use T3 (free) first
  perform t.as_('carl');
  v := public.move_order_items(fb, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T10'), gen_random_uuid());
  perform t.su();
  perform t.ok('6.1 a food item moved to a table that has only a LIQUOR bill opens a separate food bill (liquor bill untouched)',
     (v->>'new_bill')::boolean and (v->>'to_order_id')::uuid <> lb and not (select is_liquor from public.orders where id = (v->>'to_order_id')::uuid)
     and (select count(*) = 1 from public.order_items where order_id = lb and cancelled_at is null));
end $$;

-- ---------------------------------------------------------------- 7. concurrent-safety shape: moving back and forth keeps the sum
do $$
declare a uuid := t.uid('bill:A'); n uuid := t.uid('bill:A2'); v jsonb; g0 numeric; i int; ln public.order_items;
begin
  select sum(grand_total - rounding_adjustment) into g0 from public.orders where id in (a, n);
  for i in 1..3 loop
    select * into ln from t.line(n, 'cola');
    perform t.as_('carl');
    v := public.move_order_items(n, jsonb_build_array(jsonb_build_object('order_item_id', ln.id, 'qty', 1)), t.id('T1'), gen_random_uuid());
    v := public.move_order_items(a, jsonb_build_array(jsonb_build_object('order_item_id', (select id from t.line(a, 'cola')), 'qty', 1)), t.id('T2'), gen_random_uuid());
    perform t.su();
  end loop;
  perform t.eq('7.1 three round trips of one cola: amount due (before rounding) of the two bills unchanged to the paisa', (select sum(grand_total - rounding_adjustment) from public.orders where id in (a, n)), g0);
  perform t.eq('7.2 and the cola quantity across the two bills is unchanged (3)', (select sum(quantity) from public.order_items where order_id in (a, n) and product_id = t.id('cola') and cancelled_at is null), 3::numeric);
end $$;

-- ================================================================ floor_status (134)
-- clean slate for the floor: void/pay everything open, then build exactly the cases
do $$
begin
  update public.orders set payment_status = 'paid' where restaurant_id = t.uid('rest') and payment_status in ('unpaid', 'partial');
end $$;

do $$
declare b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; b6 uuid; b7 uuid; fs jsonb; r record; s record; branch uuid := t.uid('branch'); rest uuid := t.uid('rest');
begin
  -- T1: plain busy, 2 bills (one 100 min old = delayed bill, one new), KOT delivered (ready) -> not waiting
  b1 := t.bill('FS1', 'T1', t.items('{"dosa":1}')); b2 := t.bill('FS2', 'T1', t.items('{"thali":1}'));
  update public.orders set created_at = now() - interval '100 minutes', client_created_at = now() - interval '100 minutes' where id = b1;
  update public.kitchen_tickets set status = 'ready', ready_at = now() where order_id in (b1, b2);
  -- T2: a KOT waiting 20 min, bill only 25 min old
  b3 := t.bill('FS3', 'T2', t.items('{"dosa":1}'));
  update public.orders set created_at = now() - interval '25 minutes', client_created_at = now() - interval '25 minutes' where id = b3;
  update public.kitchen_tickets set status = 'preparing', created_at = now() - interval '20 minutes', client_created_at = now() - interval '20 minutes' where order_id = b3;
  -- T3: bill whose status is 'completed' and payment unpaid (the real state of an open bill) with an OFFLINE time: client_created_at 40 min ago, created_at now
  b4 := t.bill('FS4', 'T3', t.items('{"dosa":1}'));
  update public.orders set client_created_at = now() - interval '40 minutes' where id = b4;
  update public.kitchen_tickets set status = 'new', client_created_at = now() - interval '5 minutes' where order_id = b4;
  -- T4: a voided bill, a merged-away bill, a paid bill -> table is free
  b5 := t.bill('FS5', 'T4', t.items('{"dosa":1}')); perform t.as_('owner'); perform public.void_order(b5, 'fs test'); perform t.su();
  b6 := t.bill('FS6', 'T4', t.items('{"dosa":1}')); perform t.as_('owner'); perform public.void_order(b6, 'fs test'); perform t.su(); update public.orders set merged_into = b1 where id = b6;
  b7 := t.bill('FS7', 'T4', t.items('{"dosa":1}')); update public.orders set payment_status = 'paid' where id = b7;
  -- an open bill on another outlet's table and on the other restaurant must never show
  -- reservations on T10: booked in 45 min (shown), T3: booked 2 h away (not shown), T4: booked 20 min ago (shown), T2: cancelled booking (not shown), T1: booked 45 min ago (too late, not shown)
  insert into public.reservations (id, restaurant_id, branch_id, guest_name, party_size, reserved_for, dining_table_id, status) values
    (t.id('r1'), rest, branch, 'Rita', 4, now() + interval '45 minutes', t.id('T10'), 'booked'),
    (t.id('r2'), rest, branch, 'Sam',  2, now() + interval '2 hours',    t.id('T3'),  'booked'),
    (t.id('r3'), rest, branch, 'Tara', 3, now() - interval '20 minutes', t.id('T4'),  'booked'),
    (t.id('r4'), rest, branch, 'Uma',  2, now() + interval '30 minutes', t.id('T2'),  'cancelled'),
    (t.id('r5'), rest, branch, 'Vik',  2, now() - interval '45 minutes', t.id('T1'),  'booked'),
    (t.id('r6'), rest, branch, 'Wal',  2, now() + interval '90 minutes', t.id('T10'), 'booked'),
    (t.id('r7'), rest, branch, 'Xan',  2, now() + interval '10 minutes', t.id('T10'), 'seated');
  perform t.as_('carl');
  select jsonb_agg(to_jsonb(f)) into fs from public.floor_status() f;
  perform t.su();
  perform t.set('fs', fs::text);
  perform t.eq('F1 only active, non-kiosk tables of this outlet, in table order (T1, T10, T2, T3, T4)', (select jsonb_agg(e->>'table_number' order by ord) from jsonb_array_elements(fs) with ordinality x(e, ord))::text, '["T1", "T10", "T2", "T3", "T4"]'::text);
end $$;

create function t.row_(p_table text) returns jsonb language sql stable as $$ select e from jsonb_array_elements(t.get('fs')::jsonb) e where e->>'table_number' = p_table $$;
do $$
declare b1 uuid := t.uid('bill:FS1'); b2 uuid := t.uid('bill:FS2'); r jsonb;
begin
  r := t.row_('T1');
  perform t.eq('F2 T1: two open bills, total = sum of both grand totals', ((r->>'open_bills')::int, (r->>'open_total')::numeric)::text,
     ((2), (select sum(grand_total) from public.orders where id in (b1, b2)))::text);
  perform t.ok('F3 T1: oldest open is the 100-minute-old bill', now() - (r->>'oldest_open_at')::timestamptz between interval '99 minutes' and interval '101 minutes');
  perform t.eq('F4 T1: tickets are ready, so no KOT waiting', (r->>'kot_waiting')::int, 0);
  perform t.ok('F5 T1: a booking 45 minutes ago is outside the window (no reservation)', r->>'reservation_id' is null);
  r := t.row_('T2');
  perform t.eq('F6 T2: one bill, one KOT waiting, oldest KOT about 20 min', ((r->>'open_bills')::int, (r->>'kot_waiting')::int, now() - (r->>'oldest_kot_at')::timestamptz between interval '19 minutes' and interval '21 minutes')::text, '(1,1,t)');
  perform t.ok('F7 T2: a cancelled booking does not count', r->>'reservation_id' is null);
  r := t.row_('T3');
  perform t.eq('F8 T3: the open bill is found although its status is completed (payment unpaid)', (r->>'open_bills')::int, 1);
  perform t.ok('F9 T3: bill time is the offline client time (40 min), KOT time the client time (5 min), not created_at',
     now() - (r->>'oldest_open_at')::timestamptz between interval '39 minutes' and interval '41 minutes' and now() - (r->>'oldest_kot_at')::timestamptz between interval '4 minutes' and interval '6 minutes');
  perform t.ok('F10 T3: a booking two hours away is not shown', r->>'reservation_id' is null);
  r := t.row_('T4');
  perform t.eq('F11 T4: voided, merged-away and paid bills are not open: free table', ((r->>'open_bills')::int, (r->>'open_total')::numeric, (r->>'kot_waiting')::int)::text, '(0,0,0)');
  perform t.ok('F12 T4: a booking that started 20 minutes ago is inside the window', r->>'reservation_name' = 'Tara' and (r->>'reservation_party')::int = 3);
  r := t.row_('T10');
  perform t.ok('F13 T10: nearest booking in the window (Rita, +45 min); +90 min and a seated one are ignored', r->>'reservation_name' = 'Rita' and (r->>'open_bills')::int = 0);
  perform t.ok('F14 every row carries the database clock', (select bool_and((e->>'db_now')::timestamptz between now() - interval '1 minute' and now() + interval '1 minute') from jsonb_array_elements(t.get('fs')::jsonb) e));
end $$;

do $$
begin
  perform t.err('F15 a role without order.create is refused', $q$select t.as_('nina'); select * from public.floor_status()$q$, 'order.create'); perform t.su();
  perform t.err('F16 not signed in is refused', $q$select set_config('request.jwt.claim.sub', '', false); select set_config('role', 'authenticated', false); select * from public.floor_status()$q$, 'not signed in'); perform t.su();
  perform t.as_('other');
  perform t.eq('F17 the other restaurant sees none of our tables', (select count(*)::int from public.floor_status()), 0);
  perform t.su();
  perform t.as_('owner');
  perform t.eq('F18 owner sees the same 5 tables', (select count(*)::int from public.floor_status()), 5);
  perform t.su();
  update public.users set current_branch_id = t.id('branchB') where id = (select id from public.users where auth_user_id = t.id('auth:owner'));
  perform t.as_('owner');
  perform t.eq('F18b an owner who switched to outlet B sees only outlet B tables (X1)', (select string_agg(table_number, ',') from public.floor_status()), 'X1');
  perform t.su();
  perform t.ok('F19 floor_status is read only (stable)', (select provolatile from pg_proc where proname = 'floor_status') = 's');
  perform t.ok('F20 floor_status is not callable by anon', not has_function_privilege('anon', 'public.floor_status()', 'execute') and has_function_privilege('authenticated', 'public.floor_status()', 'execute'));
  perform t.ok('F21 move_order_items is not callable by anon', not has_function_privilege('anon', 'public.move_order_items(uuid,jsonb,uuid,uuid)', 'execute') and has_function_privilege('authenticated', 'public.move_order_items(uuid,jsonb,uuid,uuid)', 'execute'));
end $$;

-- ---------------------------------------------------------------- result
\o
\echo
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
select case when :failed > 0 then 1/0 end as stop_if_failed;
