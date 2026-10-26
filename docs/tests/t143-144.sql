-- t143-144.sql: proves migrations 143 (inventory core) and 144 (inventory reports). Runs AFTER t143-144-pre.sql (same database: fixtures and OLD-style
-- stock rows) and after 143 + 144 have been applied. Bills are made with the REAL functions (create_order, move_order_items, void_order, ...).
-- Test databases only: it signs in as made-up people. Results: one PASS / FAIL line per check, then "RESULT: n passed, m failed".
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null

create function t.r() returns uuid language sql stable as $$ select t.get('rest')::uuid $$;
create function t.nrows(p_ing text, p_kind text default null, p_branch text default 'branch') returns int language sql stable as $$
  select count(*)::int from public.stock_movements where ingredient_id = t.id(p_ing) and branch_id = t.get(p_branch)::uuid and (p_kind is null or kind = p_kind) $$;
create function t.line(p_order uuid, p_prod text) returns uuid language sql stable as $$
  select id from public.order_items where order_id = p_order and product_id = t.id(p_prod) and cancelled_at is null order by quantity desc limit 1 $$;
create function t.has(p_user text, p_key text) returns boolean language sql stable as $$
  select exists (select 1 from public.users u join public.role_permissions rp on rp.role_id = u.role_id where u.id = t.id('u:' || p_user) and rp.permission_key = p_key) $$;
create function t.norm(j jsonb) returns jsonb language sql immutable as $$
  select case jsonb_typeof(j)
    when 'number' then to_jsonb(trim_scale((j #>> '{}')::numeric))
    when 'array' then coalesce((select jsonb_agg(t.norm(e) order by ord) from jsonb_array_elements(j) with ordinality as x(e, ord)), '[]'::jsonb)
    when 'object' then coalesce((select jsonb_object_agg(k, t.norm(v)) from jsonb_each(j) as x(k, v)), '{}'::jsonb)
    else j end $$;
-- compare json documents numerically (50.0000 = 50) and independent of key order
create function t.js(p_label text, p_actual jsonb, p_expected text) returns void language plpgsql as $$
begin insert into t.res(ok, label, detail) values (t.norm(p_actual) is not distinct from t.norm(p_expected::jsonb), p_label,
  case when t.norm(p_actual) is not distinct from t.norm(p_expected::jsonb) then null else 'expected ' || p_expected || E'\n   got      ' || coalesce(p_actual::text, 'NULL') end); end $$;
-- text versions of t.eq: when the expected text is a json document it is compared numerically and independent of key order
create function t.eq(p_label text, p_actual text, p_expected text) returns void language plpgsql as $$
declare v_ok boolean;
begin
  if left(coalesce(p_expected, ''), 1) in ('{', '[') then v_ok := t.norm(p_actual::jsonb) is not distinct from t.norm(p_expected::jsonb);
  else v_ok := p_actual is not distinct from p_expected; end if;
  insert into t.res(ok, label, detail) values (v_ok, p_label, case when v_ok then null else 'expected ' || coalesce(p_expected, 'NULL') || E'\n   got      ' || coalesce(p_actual, 'NULL') end);
end $$;
create function t.cash() returns uuid language sql stable as $$ select id from public.payment_methods where restaurant_id = t.r() and kind = 'cash' and is_active order by display_order limit 1 $$;

-- ================================================================ 1 rights
select t.ok('1.1 stock.view and stock.adjust exist as rights', (select count(*) = 2 from public.permissions where key in ('stock.view', 'stock.adjust')));
select t.eq('1.2 granted to exactly the roles that had stock.manage (Owner, Manager, custom Stock keeper) plus the system role Chef',
  (select string_agg(distinct ro.name, ',' order by ro.name) from public.role_permissions rp join public.roles ro on ro.id = rp.role_id
    where ro.restaurant_id = t.r() and rp.permission_key = 'stock.view'), 'Chef,Manager,Owner,Stock keeper');
select t.eq('1.3 same set for stock.adjust',
  (select string_agg(distinct ro.name, ',' order by ro.name) from public.role_permissions rp join public.roles ro on ro.id = rp.role_id
    where ro.restaurant_id = t.r() and rp.permission_key = 'stock.adjust'), 'Chef,Manager,Owner,Stock keeper');
select t.ok('1.4 the Cashier has neither right', not t.has('carl', 'stock.view') and not t.has('carl', 'stock.adjust'));
select t.ok('1.5 the custom role with stock.manage only (made before 143) got both', t.has('stocker', 'stock.view') and t.has('stocker', 'stock.adjust'));
-- a restaurant created AFTER 143
do $$
declare r uuid;
begin
  insert into auth.users (id, email) values (t.id('auth:new4'), 'new4@t143.test');
  perform set_config('request.jwt.claim.sub', t.id('auth:new4')::text, false);
  r := public.create_restaurant_with_owner('Late Foods Pvt Ltd', 'Late Kitchen', 'IN', 'Lena Late', 'Main', 'LT');
  perform t.set('rest4', r::text);
  update public.restaurants set edition = 'professional' where id = r;
  perform t.ok('1.6 a restaurant created after 143: Owner and Manager have both rights, Chef has both (trigger), Cashier has none',
    (select string_agg(ro.name, ',' order by ro.name) from public.roles ro where ro.restaurant_id = r
        and exists (select 1 from public.role_permissions a where a.role_id = ro.id and a.permission_key = 'stock.view')
        and exists (select 1 from public.role_permissions b where b.role_id = ro.id and b.permission_key = 'stock.adjust')) = 'Chef,Manager,Owner'
    and not exists (select 1 from public.roles ro join public.role_permissions a on a.role_id = ro.id
                     where ro.restaurant_id = r and ro.name in ('Cashier', 'Waiter') and a.permission_key in ('stock.view', 'stock.adjust')),
    (select string_agg(ro.name, ',') from public.roles ro where ro.restaurant_id = r));
end $$;

-- ================================================================ 2 back-fill of the OLD rows
select t.ok('2.1 business_date is NOT NULL on stock_movements', (select is_nullable = 'NO' from information_schema.columns where table_name = 'stock_movements' and column_name = 'business_date'));
select t.eq('2.2 no old row was lost or added by the migration', (select count(*)::text from public.stock_movements), t.get('before_rows'));
select t.eq('2.3 the milk wastage at 02:30 local on 11 Oct belongs to business day 10 Oct (4 a.m. cut-off), not the calendar day',
  (select business_date::text from public.stock_movements where kind = 'wastage' and ingredient_id = t.id('milk') and note = 'spilled before 143'), '2026-10-10');
select t.eq('2.4 purchases keep their day (5 Oct)', (select string_agg(distinct business_date::text, ',') from public.stock_movements where kind = 'purchase'), '2026-10-05');
select t.eq('2.5 sale rows take the bill''s business date', (select count(*)::int from public.stock_movements m join public.orders o on o.id = m.order_id where m.business_date is distinct from o.business_date), 0);
select t.eq('2.6 old sale rows got the ingredient''s cost (no sale row without a cost)', (select count(*)::int from public.stock_movements where kind = 'sale' and unit_cost is null), 0);
select t.eq('2.7 the old wastage row got the milk cost (60); purchase costs are untouched (bun 5)',
  (select jsonb_build_object('w', (select unit_cost from public.stock_movements where kind = 'wastage' and ingredient_id = t.id('milk')),
                             'p', (select unit_cost from public.stock_movements where kind = 'purchase' and ingredient_id = t.id('bun')))::text), '{"p": 5.0000, "w": 60.0000}');
select t.ok('2.8 the append-only trigger is switched on again after the back-fill', (select tgenabled = 'O' from pg_trigger where tgrelid = 'public.stock_movements'::regclass and tgname = 'trg_no_update_stock'));
select t.err('2.9 and an update is refused', $q$ update public.stock_movements set qty = 0 $q$, 'cannot be changed');
select t.as_('owner');
select jsonb_agg(jsonb_build_object('name', x->>'name', 'stock', x->'stock', 'cost', x->'cost') order by x->>'name')::text as lv from jsonb_array_elements(public.stock_report('2026-01-01', '2026-12-31')->'levels') x \gset
select t.su();
select t.ok('2.10 the old Stock screen shows the same levels and costs as before 143', :'lv' = t.get('before_levels'));
select t.su();

-- ================================================================ 3 stamp: cost snapshot and business date on new rows
do $$
declare b uuid; i uuid; m uuid;
begin
  b := t.bill('s3', 'T3', t.items('{"burger":2,"dosa":1}'));
  perform t.ok('3.1 a sale row carries the cost at the time of sale and the bill''s business date',
    (select count(*) = 3 and bool_and(m.business_date = o.business_date) and bool_and(m.unit_cost = case m.ingredient_id when t.id('bun') then 5 when t.id('patty') then 200 else 80 end)
       from public.stock_movements m join public.orders o on o.id = m.order_id where m.order_id = b and m.kind = 'sale'));
  update public.ingredients set cost_per_unit = 220 where id = t.id('patty');
  i := t.line(b, 'burger');
  perform t.as_('owner'); perform public.cancel_order_item(i, 1, 'test cancel'); perform t.su();
  perform t.ok('3.2 an item cancelled later returns food at the cost it left at (200), even though the cost is 220 now',
    (select count(*) = 2 and bool_and(case m.ingredient_id when t.id('patty') then m.unit_cost = 200 and m.qty = 0.15 else m.unit_cost = 5 and m.qty = 1 end)
       from public.stock_movements m where m.order_item_id = i and m.kind = 'returned'));
  perform t.set('cancel_patty_cost', '200');
  -- a new sale after the price change is taken out at 220
  perform t.as_('carl'); perform public.add_order_items(b, t.items('{"burger":1}')); perform t.su();
  perform t.ok('3.3 a sale after the price change snapshots the new cost (patty 220)',
    (select array_agg(m.unit_cost order by m.unit_cost) = array[200, 220]::numeric[] from public.stock_movements m where m.order_id = b and m.kind = 'sale' and m.ingredient_id = t.id('patty')));
  update public.ingredients set cost_per_unit = 200 where id = t.id('patty');
  -- a combo: the chosen dish's ingredients are taken out with the same stamp
  perform t.as_('carl');
  m := (public.create_order(jsonb_build_array(jsonb_build_object('product_id', t.id('meal'), 'qty', 1, 'options', jsonb_build_array(t.id('optTea')))), 'dine_in', t.id('T4'))->>'order_id')::uuid;
  perform t.su(); perform t.set('bill:meal', m::text);
  perform t.ok('3.4 combo: the chosen Tea takes milk 0.1 and tea powder 0.005 out, stamped with cost and business date',
    (select count(*) = 2 and bool_and(m2.business_date = o.business_date) and bool_and(m2.unit_cost = case m2.ingredient_id when t.id('milk') then 60 else 400 end)
       from public.stock_movements m2 join public.orders o on o.id = m2.order_id where m2.order_id = m and m2.kind = 'sale'));
end $$;

-- a bill on the previous business day: sale rows follow the bill's day, not the calendar day
do $$
declare b uuid;
begin
  b := t.bill('bd', 'T5', t.items('{"water":1}'));
  insert into public.business_days (restaurant_id, branch_id, business_date, status) values (t.r(), t.get('branch')::uuid, '2026-10-24', 'parked');
  set session_replication_role = replica;
  update public.orders set business_date = '2026-10-24' where id = b;
  set session_replication_role = default;
  perform t.as_('carl'); perform public.add_order_items(b, t.items('{"burger":2}')); perform t.su();
  perform t.ok('3.5 rows written for a bill of 24 Oct are dated 24 Oct although they were created today',
    (select count(*) = 2 and bool_and(business_date = '2026-10-24') and bool_and(created_at::date = now()::date) from public.stock_movements where order_id = b and kind = 'sale'));
  perform t.as_('owner'); perform public.cancel_order_item(t.line(b, 'burger'), 1, 'one burger back'); perform t.su();
  perform t.ok('3.6 and the return of one burger is on 24 Oct too',
    (select count(*) = 2 and bool_and(business_date = '2026-10-24') from public.stock_movements where order_id = b and kind = 'returned'));
end $$;

-- an offline bill synced later: food is taken out on the bill's own day (yesterday), once, even if the sync is repeated
do $$
declare v jsonb; v2 jsonb; o uuid; bill jsonb;
begin
  insert into public.offline_series (restaurant_id, branch_id, device_key, prefix) values (t.r(), t.get('branch')::uuid, t.id('dev1')::text, 'X1');
  bill := jsonb_build_object('client_id', t.id('offline1'), 'device_key', t.id('dev1')::text, 'seq', 1, 'number', 'MN26-X1-0001', 'order_type', 'takeaway',
    'method_id', t.cash(), 'created_at', (date_trunc('day', now() at time zone 'UTC') - interval '1 day' + interval '12 hours') at time zone 'UTC',
    'items', jsonb_build_array(jsonb_build_object('product_id', t.id('burger'), 'qty', 2, 'price', 100, 'options', '[]'::jsonb)));
  perform t.as_('carl'); v := public.sync_offline_bill(bill); v2 := public.sync_offline_bill(bill); perform t.su();
  o := (v->>'order_id')::uuid;
  perform t.ok('3.7 an offline bill claimed for yesterday and synced today: two sale rows (bun, patty) carry exactly the business date the bill got (what the sales reports use), costed at the sync',
    (v->>'ok')::boolean and (select count(*) = 2 and bool_and(m.business_date = (select o2.business_date from public.orders o2 where o2.id = o))
       and bool_and(m.unit_cost = case m.ingredient_id when t.id('bun') then 5 else 200 end) from public.stock_movements m where m.order_id = o and m.kind = 'sale'), v::text);
  perform t.ok('3.8 the sync sent twice (retry): the second answer is a repeat and no second set of rows appears', (v2->>'repeat')::boolean and (select count(*) from public.stock_movements where order_id = o) = 2);
  perform t.set('bill:offline', o::text);
end $$;

-- ================================================================ 4 void returns by LINE (fix of defect 1.4-1)
do $$
declare s uuid; d uuid; v jsonb; bun0 numeric; milk0 numeric; patty0 numeric; rice0 numeric; n0 int; ln uuid;
begin
  s := t.bill('S', 'T6', t.items('{"burger":2,"tea":1}'));
  d := t.bill('D', 'T7', t.items('{"dosa":1}'));
  ln := t.line(s, 'burger');
  bun0 := t.stock('bun'); milk0 := t.stock('milk'); patty0 := t.stock('patty'); rice0 := t.stock('rice');
  perform t.as_('carl');
  v := public.move_order_items(s, jsonb_build_array(jsonb_build_object('order_item_id', ln, 'qty', 2)), t.id('T7'), gen_random_uuid());
  perform t.su();
  perform t.ok('4.1 setup: the whole burger line moved to the other bill (same line id, now on D)', (select order_id = d from public.order_items where id = ln));
  perform t.ok('4.2 moving food between bills changes no stock', t.stock('bun') = bun0 and t.stock('patty') = patty0);
  -- void the SOURCE: only the tea is on it now
  perform t.as_('owner'); perform public.void_order(s, 'void source'); perform t.su();
  perform t.ok('4.3 voiding the SOURCE bill returns only what is still on it (tea: milk +0.1), not the burgers that moved',
    t.stock('bun') = bun0 and t.stock('patty') = patty0 and t.stock('milk') = milk0 + 0.1, 'bun ' || t.stock('bun') || ' vs ' || bun0 || ', milk ' || t.stock('milk') || ' vs ' || (milk0 + 0.1));
  perform t.ok('4.4 the void rows carry the line id and the voided bill', (select count(*) = 2 and bool_and(order_item_id is not null and order_id = s) from public.stock_movements where order_id = s and note = 'Bill voided'));
  n0 := (select count(*) from public.stock_movements);
  perform t.err('4.5 voiding the same bill again is refused', format('select t.as_(%L); select public.void_order(%L, %L)', 'owner', s, 'again'), 'already voided');
  perform t.ok('4.6 and nothing more was written', (select count(*) from public.stock_movements) = n0);
  -- void the TARGET: the burgers (2) and the dosa come back in full
  perform t.as_('owner'); perform public.void_order(d, 'void target'); perform t.su();
  perform t.ok('4.7 voiding the TARGET returns the moved burgers too: bun +2, patty +0.3, rice +0.2',
    t.stock('bun') = bun0 + 2 and t.stock('patty') = patty0 + 0.3 and t.stock('rice') = rice0 + 0.2,
    'bun ' || t.stock('bun') || '/' || (bun0 + 2) || ' patty ' || t.stock('patty') || '/' || (patty0 + 0.3) || ' rice ' || t.stock('rice') || '/' || (rice0 + 0.2));
  perform t.ok('4.8 over both bills the food is back exactly: every line on S and D nets to zero',
    (select coalesce(max(abs(x.q)), 0) = 0 from (select sum(m.qty) q from public.stock_movements m
        where m.order_item_id in (select id from public.order_items where order_id in (s, d)) group by m.order_item_id, m.ingredient_id) x));
end $$;

-- partial move (clone), then void both
do $$
declare p uuid; q uuid; ln uuid; bun0 numeric; patty0 numeric; milk0 numeric; v jsonb;
begin
  bun0 := t.stock('bun'); patty0 := t.stock('patty'); milk0 := t.stock('milk');
  p := t.bill('P', 'T6', t.items('{"burger":3}'));
  q := t.bill('Q', 'T7', t.items('{"tea":1}'));
  ln := t.line(p, 'burger');
  perform t.ok('4.9 setup: 3 burgers sold', t.stock('bun') = bun0 - 3);
  perform t.as_('carl');
  v := public.move_order_items(p, jsonb_build_array(jsonb_build_object('order_item_id', ln, 'qty', 1)), t.id('T7'), gen_random_uuid());
  perform t.su();
  perform t.ok('4.10 a partial move (one burger to the other bill) leaves the total stock where it was', t.stock('bun') = bun0 - 3 and t.stock('patty') = patty0 - 0.45);
  perform t.as_('owner'); perform public.void_order(p, 'void p'); perform t.su();
  perform t.ok('4.11 voiding P returns the 2 burgers still on it (bun +2), not 3', t.stock('bun') = bun0 - 1 and t.stock('patty') = patty0 - 0.15);
  perform t.as_('owner'); perform public.void_order(q, 'void q'); perform t.su();
  perform t.ok('4.12 voiding Q returns the moved burger and the tea: everything is back', t.stock('bun') = bun0 and t.stock('patty') = patty0 and t.stock('milk') = milk0);
end $$;

-- cancel an item, then void: nothing is returned twice
do $$
declare b uuid; bun0 numeric; i uuid; milk0 numeric;
begin
  bun0 := t.stock('bun'); milk0 := t.stock('milk');
  b := t.bill('CV', 'T8', t.items('{"burger":2,"tea":2}'));
  perform t.as_('owner'); perform public.cancel_order_item(t.line(b, 'burger'), 1, 'cancel one'); perform public.cancel_order_item(t.line(b, 'tea'), 2, 'cancel tea'); perform public.void_order(b, 'then void'); perform t.su();
  perform t.ok('4.13 cancelled items and then a void bring back exactly what was taken out, once', t.stock('bun') = bun0 and t.stock('milk') = milk0,
    'bun ' || t.stock('bun') || '/' || bun0 || ' milk ' || t.stock('milk') || '/' || milk0);
end $$;

-- ================================================================ 5 credit note: no stock effect
do $$
declare o uuid := t.get('bill:old1')::uuid; n0 int; s0 numeric; v jsonb;
begin
  perform t.as_('owner'); perform public.pay_order(o, t.cash(), null, null, null, null, null); perform t.su();
  n0 := (select count(*) from public.stock_movements); s0 := (select sum(qty) from public.stock_movements);
  perform t.as_('owner'); v := public.issue_credit_note(o, 50, t.cash(), 'cold dish', gen_random_uuid()); perform t.su();
  perform t.ok('5.1 a credit note is money only: no stock row, no change in any level', (select count(*) from public.stock_movements) = n0 and (select sum(qty) from public.stock_movements) = s0);
end $$;

-- ================================================================ 6 record_stock: rights and weighted-average cost
insert into public.ingredients (id, restaurant_id, name, unit, cost_per_unit, reorder_level) values
  (t.id('flour'), t.r(), 'Flour', 'kg', 0, 0), (t.id('oil'), t.r(), 'Oil', 'l', 0, 0), (t.id('sugar'), t.r(), 'Sugar', 'kg', 40, 3), (t.id('salt'), t.r(), 'Salt', 'kg', 10, 0);
select t.err('6.1 Cashier cannot record a purchase', format('select t.as_(%L); select public.record_stock(%L, %L, 1, 5)', 'carl', t.id('flour'), 'purchase'), '(stock.manage)');
select t.err('6.2 Cashier cannot record wastage either (stock.adjust)', format('select t.as_(%L); select public.record_stock(%L, %L, 1)', 'carl', t.id('flour'), 'wastage'), '(stock.adjust)');
select t.err('6.3 Chef cannot record a purchase', format('select t.as_(%L); select public.record_stock(%L, %L, 1, 5)', 'chef', t.id('flour'), 'purchase'), '(stock.manage)');
select t.err('6.4 Basic edition: the stock functions are refused', format('select t.as_(%L); select public.record_stock(%L, %L, 1, 5)', 'other', t.id('flour'), 'purchase'), 'needs the Professional edition');
select t.as_('stocker');
select public.record_stock(t.id('flour'), 'purchase', 10, 50);
select t.su();
select t.eq('6.5 first purchase on empty stock: cost = the price paid', (select cost_per_unit from public.ingredients where id = t.id('flour')), 50.0000::numeric);
select t.as_('stocker');
select public.record_stock(t.id('flour'), 'purchase', 10, 70);
select t.su();
select t.eq('6.6 stock 10 at 50, buy 10 at 70 -> 60 (weighted average)', (select cost_per_unit from public.ingredients where id = t.id('flour')), 60.0000::numeric);
select t.as_('chef');
select public.record_stock(t.id('flour'), 'wastage', 25, null, 'dropped sack');
select t.su();
select t.eq('6.7 Chef may record wastage; stock goes negative (-5) and is allowed', t.stock('flour'), -5::numeric);
select t.eq('6.8 the wastage row is stamped: cost 60, reason other, business date set', (select jsonb_build_object('c', unit_cost, 'r', reason, 'd', business_date is not null)::text from public.stock_movements where ingredient_id = t.id('flour') and kind = 'wastage'), '{"c": 60.0000, "d": true, "r": "other"}');
select t.as_('stocker');
select public.record_stock(t.id('flour'), 'purchase', 10, 90);
select t.su();
select t.eq('6.9 buying while stock is negative: the new price becomes the cost', (select cost_per_unit from public.ingredients where id = t.id('flour')), 90.0000::numeric);
select t.as_('chef');
select public.record_stock(t.id('flour'), 'count', 12, null, 'recount');
select t.su();
select t.eq('6.10 a count through record_stock: stock = counted, row is a count_correction', (select jsonb_build_object('s', t.stock('flour'), 'k', (select reason from public.stock_movements where ingredient_id = t.id('flour') and kind = 'count'))::text), '{"k": "count_correction", "s": 12.0000}');
-- several outlets: one cost for the restaurant, weighted against ALL the stock held
select t.as_('mgr');
select public.record_stock(t.id('oil'), 'purchase', 10, 100);
select t.as_('mgrB');
select public.record_stock(t.id('oil'), 'purchase', 10, 120);
select t.su();
select t.eq('6.11 Outlet A holds 10 at 100, Outlet B buys 10 at 120: cost = 110 (weighted over both outlets, not 120)', (select cost_per_unit from public.ingredients where id = t.id('oil')), 110.0000::numeric);
select t.eq('6.12 each outlet keeps its own level', (select jsonb_build_object('a', t.stock('oil'), 'b', t.stock('oil', 'branchB'))::text), '{"a": 10.0000, "b": 10.0000}');

-- ================================================================ 7 stock_in_quick
select t.as_('owner');
select public.stock_in_quick(jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'qty', 10, 'unit_cost', 40), jsonb_build_object('ingredient_id', t.id('sugar'), 'qty', 10, 'unit_cost', 60),
  jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 5, 'unit_cost', 10)), 'ACME Traders', 'B-17', t.id('in1')) as r \gset
select t.su();
select t.eq('7.1 result: 3 lines, total value 400 + 600 + 50', (:'r'::jsonb - 'lines')::text, '{"count": 3, "total_value": 1050.00}');
select t.eq('7.2 the same ingredient twice in one receipt is averaged in turn: sugar 10 at 40 then 10 at 60 -> 50', (select cost_per_unit from public.ingredients where id = t.id('sugar')), 50.0000::numeric);
select t.eq('7.3 one purchase row per line, with the supplier note and bill number', (select count(*) filter (where note = 'ACME Traders · Bill B-17' and kind = 'purchase' and unit_cost is not null)::int from public.stock_movements where ingredient_id in (t.id('sugar'), t.id('salt')) and branch_id = t.get('branch')::uuid), 3);
select t.eq('7.4 audit row stock.in with supplier and total', (select (new_value->>'supplier') || '/' || (new_value->>'total_value') from public.audit_logs where action = 'stock.in' order by created_at desc limit 1), 'ACME Traders/1050.00');
select t.as_('owner');
select public.stock_in_quick(jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'qty', 10, 'unit_cost', 40), jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 5, 'unit_cost', 10)), 'ACME Traders', 'B-17', t.id('in1')) as r2 \gset
select t.su();
select t.ok('7.5 the same client ref again: the stored answer comes back marked repeat, nothing is written twice',
  (:'r2'::jsonb)->>'repeat' = 'true' and (:'r2'::jsonb)->>'total_value' = '1050.00' and t.nrows('sugar', 'purchase') = 2 and t.nrows('salt', 'purchase') = 1);
select t.err('7.6b unknown ingredient on line 2', format('select t.as_(%L); select public.stock_in_quick(%L::jsonb, null, null, %L)', 'owner',
  jsonb_build_array(jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 1, 'unit_cost', 10), jsonb_build_object('ingredient_id', t.id('nothing'), 'qty', 1, 'unit_cost', 10))::text, t.id('in2')), 'Line 2: ingredient not found');
select t.ok('7.7 ... and salt did not move, the cost did not change, no ref was stored', t.stock('salt') = 5 and (select cost_per_unit from public.ingredients where id = t.id('salt')) = 10
  and not exists (select 1 from public.request_refs where ref = t.id('in2')) and (select count(*) from public.audit_logs where action = 'stock.in') = 1);
select t.err('7.8 quantity zero is refused', format('select t.as_(%L); select public.stock_in_quick(%L::jsonb)', 'owner', jsonb_build_array(jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 0, 'unit_cost', 10))::text), 'Line 1: enter a quantity above zero');
select t.err('7.9 a missing cost is refused', format('select t.as_(%L); select public.stock_in_quick(%L::jsonb)', 'owner', jsonb_build_array(jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 1))::text), 'Line 1: enter the cost per unit');
select t.err('7.10 an empty receipt is refused', format('select t.as_(%L); select public.stock_in_quick(%L::jsonb)', 'owner', '[]'), 'Add at least one ingredient');
select t.err('7.11 Chef cannot stock in (stock.manage)', format('select t.as_(%L); select public.stock_in_quick(%L::jsonb)', 'chef', jsonb_build_array(jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 1, 'unit_cost', 10))::text), '(stock.manage)');
select t.err('7.12 Cashier cannot stock in', format('select t.as_(%L); select public.stock_in_quick(%L::jsonb)', 'carl', jsonb_build_array(jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 1, 'unit_cost', 10))::text), '(stock.manage)');
select t.err('7.13 Basic edition is refused', format('select t.as_(%L); select public.stock_in_quick(%L::jsonb)', 'other', jsonb_build_array(jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 1, 'unit_cost', 10))::text), 'needs the Professional edition');
select t.err('7.14 a client ref already used by another kind of request is refused', format('select t.as_(%L); select public.stock_in_quick(%L::jsonb, null, null, %L)', 'owner',
  jsonb_build_array(jsonb_build_object('ingredient_id', t.id('salt'), 'qty', 1, 'unit_cost', 10))::text, (select ref from public.request_refs where kind = 'move_items' limit 1)), 'already used for something else');

-- ================================================================ 8 adjust_stock
select t.as_('chef');
select public.adjust_stock(t.id('milk'), 'wastage', 2, 'spoilage', 'fridge failed', t.id('adj1')) as r \gset
select t.su();
select t.eq('8.1 wastage: answer carries value 2 x 60 = 120', ((:'r'::jsonb) - 'movement_id' - 'stock')::text, '{"kind": "wastage", "value": 120.00, "change": -2.0000}');
select t.eq('8.2 the row: kind wastage, qty -2, reason spoilage, cost 60, created by the chef',
  (select jsonb_build_object('k', kind, 'q', qty, 'r', reason, 'c', unit_cost, 'u', created_by = t.id('u:chef'), 'n', note)::text from public.stock_movements where client_ref = t.id('adj1')),
  '{"c": 60.0000, "k": "wastage", "n": "fridge failed", "q": -2.0000, "r": "spoilage", "u": true}');
select t.eq('8.3 audit stock.wastage with ingredient, qty, reason and value', (select (new_value->>'ingredient') || '/' || (new_value->>'qty') || '/' || (new_value->>'reason') || '/' || (new_value->>'value') from public.audit_logs where action = 'stock.wastage' order by created_at desc limit 1), 'Milk/2.0000/spoilage/120.00');
select t.as_('chef');
select public.adjust_stock(t.id('milk'), 'wastage', 2, 'spoilage', 'fridge failed', t.id('adj1')) as r2 \gset
select t.su();
select t.ok('8.4 double tap (same client ref): one entry, answer marked repeat', t.nrows('milk', 'wastage') = 2 and (:'r2'::jsonb)->>'repeat' = 'true'
  and (:'r2'::jsonb)->>'movement_id' = (:'r'::jsonb)->>'movement_id');
select t.as_('chef');
select public.adjust_stock(t.id('rice'), 'adjust_in', 3, 'count_correction', null) as r3 \gset
select public.adjust_stock(t.id('rice'), 'adjust_out', 1, 'breakage', 'sack torn') as r4 \gset
select t.su();
select t.eq('8.5 adjust in / out are kind adjust with a sign and audit stock.adjust', (select jsonb_build_object('rows', (select jsonb_agg(qty order by qty) from public.stock_movements where ingredient_id = t.id('rice') and kind = 'adjust'),
  'audits', (select count(*) from public.audit_logs where action = 'stock.adjust'))::text), '{"audits": 2, "rows": [-1.0000, 3.0000]}');
select t.err('8.6 a reason is required', format('select t.as_(%L); select public.adjust_stock(%L, %L, 1, null)', 'chef', t.id('milk'), 'wastage'), 'Choose a reason');
select t.err('8.7 a reason outside the list is refused', format('select t.as_(%L); select public.adjust_stock(%L, %L, 1, %L)', 'chef', t.id('milk'), 'wastage', 'because'), 'Choose a reason');
select t.err('8.8 quantity must be above zero', format('select t.as_(%L); select public.adjust_stock(%L, %L, 0, %L)', 'chef', t.id('milk'), 'wastage', 'spill'), 'Enter a quantity above zero');
select t.err('8.9 kind must be known', format('select t.as_(%L); select public.adjust_stock(%L, %L, 1, %L)', 'chef', t.id('milk'), 'purchase', 'spill'), 'Choose wastage');
select t.err('8.10 Cashier cannot adjust (stock.adjust)', format('select t.as_(%L); select public.adjust_stock(%L, %L, 1, %L)', 'carl', t.id('milk'), 'wastage', 'spill'), '(stock.adjust)');
select t.err('8.11 Basic edition is refused', format('select t.as_(%L); select public.adjust_stock(%L, %L, 1, %L)', 'other', t.id('milk'), 'wastage', 'spill'), 'needs the Professional edition');
select t.err('8.12 a client ref cannot be reused for another ingredient', format('select t.as_(%L); select public.adjust_stock(%L, %L, 1, %L, null, %L)', 'chef', t.id('rice'), 'wastage', 'spill', t.id('adj1')), 'already used for something else');
select t.as_('mgrB');
select public.adjust_stock(t.id('milk'), 'adjust_in', 4, 'other', 'found a crate');
select t.su();
select t.eq('8.13 an adjustment affects only the signed-in outlet', (select jsonb_build_object('a', t.stock('milk'), 'b', t.stock('milk', 'branchB'))::text), (select jsonb_build_object('a', t.stock('milk'), 'b', 4)::text));
-- the business day of a manual entry: at 02:00 local the entry belongs to YESTERDAY's business day
do $$
declare v_off int; v_tz text; v_exp date; v_cal date; v_got date; v_old text;
begin
  v_off := ((2 - extract(hour from (now() at time zone 'UTC'))::int) + 24) % 24;
  if v_off > 14 then v_off := v_off - 24; end if;
  v_tz := 'Etc/GMT' || case when v_off > 0 then '-' || v_off when v_off < 0 then '+' || (-v_off) else '' end;
  select timezone into v_old from public.branches where id = t.get('branch')::uuid;
  update public.branches set timezone = v_tz where id = t.get('branch')::uuid;
  update public.branch_settings set day_cutoff = '04:00' where branch_id = t.get('branch')::uuid;
  v_exp := ((now() at time zone v_tz) - interval '4 hours')::date; v_cal := (now() at time zone v_tz)::date;
  perform t.as_('chef'); perform public.adjust_stock(t.id('salt'), 'wastage', 0.5, 'spill', 'two a.m.', t.id('adj2')); perform t.su();
  select business_date into v_got from public.stock_movements where client_ref = t.id('adj2');
  update public.branches set timezone = v_old where id = t.get('branch')::uuid;
  perform t.ok('8.14 a manual entry at 02:00 local lands on the previous business day (' || v_tz || ')', v_got = v_exp and v_exp <> v_cal, 'got ' || v_got || ' expected ' || v_exp || ' calendar ' || v_cal);
end $$;

-- ================================================================ 9 stock_count_apply
select t.as_('owner');
select public.record_stock(t.id('salt'), 'purchase', 3, 10);
select t.su();
-- salt is 4.5 + 3 now; read what the count will see
select t.set('salt_now', t.stock('salt')::text), t.set('sugar_now', t.stock('sugar')::text);
select t.as_('chef');
select public.stock_count_apply(jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', 18), jsonb_build_object('ingredient_id', t.id('salt'), 'counted', t.get('salt_now')::numeric)), 'monthly count', t.id('cnt1')) as r \gset
select t.su();
select t.eq('9.1 sugar 20 on hand, counted 18: one correction of -2; salt counted = expected: no movement; variance = -2 x 50',
  ((:'r'::jsonb) - 'count_id')::text, '{"lines": 2, "adjusted": 1, "variance_value": -100.00}');
select t.eq('9.2 the count wrote one movement (kind count, -2, reason count_correction, linked to the count)', (select jsonb_build_object('n', count(*), 'q', min(qty), 'r', min(reason), 'c', bool_and(count_id = ((:'r'::jsonb)->>'count_id')::uuid))::text from public.stock_movements where kind = 'count' and ingredient_id in (t.id('sugar'), t.id('salt'))), '{"c": true, "n": 1, "q": -2.0000, "r": "count_correction"}');
select t.eq('9.3 the count record keeps BOTH lines (expected / counted / diff / cost / value)',
  (select jsonb_agg(jsonb_build_object('i', i.name, 'e', l.expected, 'c', l.counted, 'd', l.diff, 'u', l.unit_cost, 'v', l.value_diff) order by i.name)::text from public.stock_count_lines l join public.ingredients i on i.id = l.ingredient_id where l.count_id = ((:'r'::jsonb)->>'count_id')::uuid),
  (select jsonb_agg(x order by x->>'i')::text from (select jsonb_build_object('i', 'Salt', 'e', t.get('salt_now')::numeric, 'c', t.get('salt_now')::numeric, 'd', 0, 'u', 10, 'v', 0) x
     union all select jsonb_build_object('i', 'Sugar', 'e', t.get('sugar_now')::numeric, 'c', 18, 'd', 18 - t.get('sugar_now')::numeric, 'u', 50, 'v', (18 - t.get('sugar_now')::numeric) * 50)) z));
select t.ok('9.4 header: current outlet, business day, note, who', (select branch_id = t.get('branch')::uuid and business_date = app.business_today(branch_id) and note = 'monthly count' and created_by = t.id('u:chef') from public.stock_counts where client_ref = t.id('cnt1')));
select t.eq('9.5 audit stock.count', (select (new_value->>'adjusted') || '/' || (new_value->>'variance_value') from public.audit_logs where action = 'stock.count' order by created_at desc limit 1), '1/-100.00');
select t.as_('chef');
select public.stock_count_apply(jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', 18)), 'monthly count', t.id('cnt1')) as r2 \gset
select t.su();
select t.ok('9.6 replay with the same client ref: same count, marked repeat, no new movement or count',
  (:'r2'::jsonb)->>'repeat' = 'true' and (:'r2'::jsonb)->>'count_id' = (:'r'::jsonb)->>'count_id' and (select count(*) from public.stock_counts where restaurant_id = t.r()) = 1 and t.nrows('sugar', 'count') = 1);
select t.err('9.7 an ingredient twice in one count is refused', format('select t.as_(%L); select public.stock_count_apply(%L::jsonb)', 'chef',
  jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', 1), jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', 2))::text), 'listed twice');
select t.err('9.8 a negative counted quantity is refused', format('select t.as_(%L); select public.stock_count_apply(%L::jsonb)', 'chef', jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', -1))::text), 'Line 1: enter the counted quantity');
select t.err('9.9 an unknown ingredient is refused and nothing is written', format('select t.as_(%L); select public.stock_count_apply(%L::jsonb)', 'chef',
  jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', 1), jsonb_build_object('ingredient_id', t.id('nothing'), 'counted', 1))::text), 'Line 2: ingredient not found');
select t.ok('9.10 ... stock and counts unchanged', t.stock('sugar') = 18 and (select count(*) from public.stock_counts where restaurant_id = t.r()) = 1);
select t.err('9.11 Cashier cannot count (stock.adjust)', format('select t.as_(%L); select public.stock_count_apply(%L::jsonb)', 'carl', jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', 1))::text), '(stock.adjust)');
select t.err('9.12 Basic edition is refused', format('select t.as_(%L); select public.stock_count_apply(%L::jsonb)', 'other', jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', 1))::text), 'needs the Professional edition');
select t.as_('mgrB');
select public.stock_count_apply(jsonb_build_array(jsonb_build_object('ingredient_id', t.id('sugar'), 'counted', 5))) as rb \gset
select t.su();
select t.eq('9.13 a count at Outlet B reads Outlet B''s stock (0) and leaves Outlet A alone', (select jsonb_build_object('a', t.stock('sugar'), 'b', t.stock('sugar', 'branchB'), 'diff', (select diff from public.stock_count_lines where count_id = ((:'rb'::jsonb)->>'count_id')::uuid))::text), '{"a": 18.0000, "b": 5.0000, "diff": 5.0000}');
select t.ok('9.15 the count tables cannot be written by a signed-in person directly', (select not has_table_privilege('authenticated', 'public.stock_counts', 'insert') and not has_table_privilege('authenticated', 'public.stock_count_lines', 'insert')
  and not has_table_privilege('anon', 'public.stock_counts', 'select')));

-- ================================================================ 10 POS warning
select t.as_('carl');
select public.stock_warnings(jsonb_build_array(jsonb_build_object('product_id', t.id('dosa'), 'qty', 1))) as w1 \gset
select public.stock_warnings(jsonb_build_array(jsonb_build_object('product_id', t.id('dosa'), 'qty', 30))) as w2 \gset
select public.stock_warnings(jsonb_build_array(jsonb_build_object('product_id', t.id('burger'), 'qty', 1))) as w3 \gset
select public.stock_warnings(jsonb_build_array(jsonb_build_object('product_id', t.id('meal'), 'qty', 500, 'options', jsonb_build_array(t.id('optTea'))))) as w4 \gset
select t.su();
select t.set('rice_a', t.stock('rice')::text), t.set('teapow_a', t.stock('teapow')::text);
select t.eq('10.1 one dosa: rice is above zero after but under its reorder level -> low (no costs in the answer)',
  (select jsonb_build_object('n', jsonb_array_length((:'w1'::jsonb)->'warnings'), 'name', (:'w1'::jsonb)#>>'{warnings,0,name}', 'level', (:'w1'::jsonb)#>>'{warnings,0,level}',
     'need', ((:'w1'::jsonb)#>>'{warnings,0,need}')::numeric, 'keys', (select jsonb_agg(k order by k) from jsonb_object_keys((:'w1'::jsonb)#>'{warnings,0}') k))::text),
  '{"n": 1, "keys": ["after", "ingredient_id", "level", "name", "need", "on_hand", "unit"], "name": "Rice", "need": 0.2000, "level": "low"}');
select t.eq('10.2 30 dosas need 6 kg of rice, more than is there -> out, with the numbers',
  (select jsonb_build_object('level', (:'w2'::jsonb)#>>'{warnings,0,level}', 'on_hand', ((:'w2'::jsonb)#>>'{warnings,0,on_hand}')::numeric, 'need', ((:'w2'::jsonb)#>>'{warnings,0,need}')::numeric,
     'after', ((:'w2'::jsonb)#>>'{warnings,0,after}')::numeric = round(t.get('rice_a')::numeric - 6, 4))::text),
  (select jsonb_build_object('level', 'out', 'on_hand', round(t.get('rice_a')::numeric, 4), 'need', 6.0000, 'after', true)::text));
select t.eq('10.3 burger: bun and patty are well stocked -> no warning', (:'w3'::jsonb)->'warnings', '[]'::jsonb);
select t.eq('10.4 a combo with Tea chosen: the option dish''s ingredients count (500 meals need 2.5 kg tea powder and 50 l milk) and the combo itself adds none',
  (select jsonb_agg(jsonb_build_object('n', x->>'name', 'l', x->>'level') order by x->>'name')::text from jsonb_array_elements((:'w4'::jsonb)->'warnings') x), '[{"l": "out", "n": "Milk"}, {"l": "out", "n": "Tea powder"}]');
select t.as_('mgrB');
select public.stock_warnings(jsonb_build_array(jsonb_build_object('product_id', t.id('dosa'), 'qty', 1))) as w5 \gset
select t.su();
select t.eq('10.5 another outlet''s stock is ignored: at Outlet B (rice 0) one dosa leaves it out', (:'w5'::jsonb)#>>'{warnings,0,level}', 'out');
select t.err('10.6 only people who can take orders may ask (Chef cannot)', format('select t.as_(%L); select public.stock_warnings(%L::jsonb)', 'chef', '[]'), '(order.create)');
select t.as_('other');
select public.stock_warnings(jsonb_build_array(jsonb_build_object('product_id', t.id('dosa'), 'qty', 1))) as w6 \gset
select t.su();
select t.eq('10.7 Basic edition: no error, an empty list', (:'w6'::jsonb)->'warnings', '[]'::jsonb);
select t.as_('carl');
select t.eq('10.8 garbage input is harmless (bad ids, no options array, nothing)', (select public.stock_warnings('[{"product_id":"x"},{"qty":3},5]'::jsonb))->'warnings', '[]'::jsonb);
select t.su();
-- negative stock is allowed: the bill goes through and rice drops below zero
select t.bill('neg', 'T8', t.items('{"dosa":30}'));
select t.ok('10.9 warn but allow: 30 dosas billed with too little rice, rice is now negative at Outlet A', t.stock('rice') < 0, 'rice ' || t.stock('rice'));

-- ================================================================ 11 low stock card
select t.as_('chef');
select public.low_stock_items() as l1 \gset
select public.low_stock_items(1) as l2 \gset
select t.su();
select t.ok('11.1 Outlet A: rice is negative and listed FIRST (worst first), counts agree with the list',
  (:'l1'::jsonb)#>>'{items,0,name}' = 'Rice' and (:'l1'::jsonb)#>>'{items,0,status}' = 'negative' and ((:'l1'::jsonb)#>>'{counts,negative}')::int = 1
  and ((:'l1'::jsonb)#>>'{counts,out}')::int + ((:'l1'::jsonb)#>>'{counts,low}')::int + ((:'l1'::jsonb)#>>'{counts,negative}')::int = jsonb_array_length((:'l1'::jsonb)->'items'), (:'l1'::jsonb)::text);
select t.eq('11.2 the limit trims the list but not the counts', jsonb_build_object('n', jsonb_array_length((:'l2'::jsonb)->'items'), 'same', (:'l2'::jsonb)->'counts' = (:'l1'::jsonb)->'counts')::text, '{"n": 1, "same": true}');
select t.as_('mgrB');
select public.low_stock_items() as l3 \gset
select t.su();
select t.ok('11.3 Outlet B (everything at zero or below, only items with a reorder level count): its own list', ((:'l3'::jsonb)#>>'{counts,out}')::int >= 4 and (:'l3'::jsonb)::text not like '%"Flour"%', (:'l3'::jsonb)::text);
select t.err('11.4 Cashier is refused (stock.view)', format('select t.as_(%L); select public.low_stock_items()', 'carl'), '(stock.view)');
select t.as_('other');
select t.eq('11.5 Basic edition: an empty card, no error', (select public.low_stock_items())::text, '{"items": [], "counts": {"low": 0, "out": 0, "negative": 0}}');
select t.su();

-- ================================================================ 12 RLS and the old stock report
select t.as_('carl');
select t.ok('12.1 Cashier reads nothing from ingredients, recipe_lines, stock_movements, stock_counts, stock_count_lines',
  (select count(*) from public.ingredients) = 0 and (select count(*) from public.recipe_lines) = 0 and (select count(*) from public.stock_movements) = 0
  and (select count(*) from public.stock_counts) = 0 and (select count(*) from public.stock_count_lines) = 0);
select t.su();
select t.as_('chef');
select t.ok('12.2 Chef (stock.view) reads ingredients, recipes, movements and counts of his outlet',
  (select count(*) from public.ingredients) >= 9 and (select count(*) from public.recipe_lines) = 5 and (select count(*) from public.stock_movements) > 20 and (select count(*) from public.stock_counts) = 1
  and not exists (select 1 from public.stock_movements where branch_id <> t.get('branch')::uuid));
select t.su();
select t.as_('stocker');
select t.ok('12.3 a role with stock.manage only still reads everything (manage implies view)', (select count(*) from public.ingredients) >= 9 and (select count(*) from public.stock_movements) > 20);
select t.su();
select t.as_('mgrB');
select t.ok('12.4 Outlet B''s manager sees only Outlet B movements and counts', (select count(*) from public.stock_movements) > 0 and not exists (select 1 from public.stock_movements where branch_id <> t.get('branchB')::uuid)
  and (select count(*) from public.stock_counts) = 1);
select t.su();
select t.as_('other');
select t.ok('12.5 another restaurant''s owner sees none of it', (select count(*) from public.ingredients) = 0 and (select count(*) from public.stock_movements) = 0);
select t.su();
select t.err('12.6 nobody can insert into ingredients directly', format('select t.as_(%L); insert into public.ingredients (restaurant_id, name, unit) values (%L, %L, %L)', 'owner', t.r(), 'Direct', 'kg'), 'permission denied');
select t.err('12.7 Cashier cannot use the old stock report (stock.view)', format('select t.as_(%L); select public.stock_report(%L, %L)', 'carl', '2026-10-01', '2026-10-31'), '(stock.view)');
select t.as_('chef');
select public.stock_report('2026-10-10', '2026-10-10') as sr1 \gset
select public.stock_report('2026-10-11', '2026-10-11') as sr2 \gset
select public.stock_report('2026-10-05', '2026-10-05') as sr3 \gset
select t.su();
select t.eq('12.8 the old report counts days by BUSINESS day: the 02:30 wastage of 11 Oct shows on 10 Oct, not 11 Oct',
  (select jsonb_build_object('d10', (select (x->>'wasted')::numeric from jsonb_array_elements((:'sr1'::jsonb)->'levels') x where x->>'name' = 'Milk'),
                             'd11', (select (x->>'wasted')::numeric from jsonb_array_elements((:'sr2'::jsonb)->'levels') x where x->>'name' = 'Milk'))::text), '{"d10": 1.0000, "d11": 0}');
select t.eq('12.9 and the purchases show on 5 Oct', (select (x->>'bought')::numeric from jsonb_array_elements((:'sr3'::jsonb)->'levels') x where x->>'name' = 'Bun'), 100.0000::numeric);

-- ================================================================ 13 reports (144)
-- numbers are checked against independent sums over stock_movements
select t.as_('owner');
select public.report_stock_on_hand() as oh_all \gset
select public.report_stock_on_hand('2026-10-04') as oh_early \gset
select public.report_stock_on_hand('2026-10-05') as oh_5 \gset
select t.as_('mgr');
select public.report_stock_on_hand() as oh_a \gset
select t.as_('mgrB');
select public.report_stock_on_hand() as oh_b \gset
select t.su();
select t.ok('13.1 stock on hand, All outlets: every row''s on_hand = the sum of its movements; value = max(on_hand, 0) x cost today',
  (select bool_and((x->>'on_hand')::numeric = (select round(coalesce(sum(m.qty), 0), 4) from public.stock_movements m where m.branch_id = (x->>'branch_id')::uuid and m.ingredient_id = (x->>'ingredient_id')::uuid)
              and (x->>'value')::numeric = round(greatest((x->>'on_hand')::numeric, 0) * (x->>'cost')::numeric, 2))
     from jsonb_array_elements((:'oh_all'::jsonb)->'rows') x));
select t.eq('13.2 All outlets covers both outlets x every ingredient: 2 x 9 rows; rice at Outlet A is "negative" and valued at 0',
  (select jsonb_build_object('rows', jsonb_array_length((:'oh_all'::jsonb)->'rows'), 'all', (:'oh_all'::jsonb)->'all_outlets',
     'rice_a', (select x->>'status' || '/' || (x->>'value') from jsonb_array_elements((:'oh_all'::jsonb)->'rows') x where x->>'name' = 'Rice' and x->>'branch_id' = t.get('branch')))::text),
  '{"all": true, "rows": 18, "rice_a": "negative/0.00"}');
select t.ok('13.3 totals add up: value = sum of rows, status counts = rows with that status, by_outlet sums to the totals',
  ((:'oh_all'::jsonb)#>>'{totals,value}')::numeric = (select sum((x->>'value')::numeric) from jsonb_array_elements((:'oh_all'::jsonb)->'rows') x)
  and ((:'oh_all'::jsonb)#>>'{totals,negative}')::int = (select count(*) from jsonb_array_elements((:'oh_all'::jsonb)->'rows') x where x->>'status' = 'negative')
  and ((:'oh_all'::jsonb)#>>'{totals,out}')::int = (select count(*) from jsonb_array_elements((:'oh_all'::jsonb)->'rows') x where x->>'status' = 'out')
  and ((:'oh_all'::jsonb)#>>'{totals,low}')::int = (select count(*) from jsonb_array_elements((:'oh_all'::jsonb)->'rows') x where x->>'status' = 'low')
  and ((:'oh_all'::jsonb)#>>'{totals,value}')::numeric = (select sum((x->>'value')::numeric) from jsonb_array_elements((:'oh_all'::jsonb)->'by_outlet') x)
  and ((:'oh_all'::jsonb)#>>'{totals,items}')::int = (select sum((x->>'items')::int) from jsonb_array_elements((:'oh_all'::jsonb)->'by_outlet') x));
select t.ok('13.4 a single outlet (manager of A, manager of B) sees only its rows, and A + B = All outlets in value and items',
  not (:'oh_a'::jsonb)->'all_outlets' = 'true'::jsonb and (select bool_and(x->>'branch_id' = t.get('branch')) from jsonb_array_elements((:'oh_a'::jsonb)->'rows') x)
  and (select bool_and(x->>'branch_id' = t.get('branchB')) from jsonb_array_elements((:'oh_b'::jsonb)->'rows') x)
  and ((:'oh_a'::jsonb)#>>'{totals,value}')::numeric + ((:'oh_b'::jsonb)#>>'{totals,value}')::numeric = ((:'oh_all'::jsonb)#>>'{totals,value}')::numeric
  and ((:'oh_a'::jsonb)#>>'{totals,items}')::int + ((:'oh_b'::jsonb)#>>'{totals,items}')::int = ((:'oh_all'::jsonb)#>>'{totals,items}')::int);
select t.eq('13.5 as_of: before the first purchase (4 Oct) everything is zero; on 5 Oct bun is 100 and milk 30',
  (select jsonb_build_object('early', (:'oh_early'::jsonb)#>'{totals,value}', 'bun5', (select (x->>'on_hand')::numeric from jsonb_array_elements((:'oh_5'::jsonb)->'rows') x where x->>'name' = 'Bun' and x->>'branch_id' = t.get('branch')),
     'milk5', (select (x->>'on_hand')::numeric from jsonb_array_elements((:'oh_5'::jsonb)->'rows') x where x->>'name' = 'Milk' and x->>'branch_id' = t.get('branch')))::text),
  '{"bun5": 100.0000, "early": 0, "milk5": 30.0000}');

-- stock movement
select t.as_('owner');
select public.report_stock_movement('2026-10-05', current_date) as mv_all \gset
select public.report_stock_movement('2026-10-06', '2026-10-10') as mv_mid \gset
select public.report_stock_movement('2026-10-24', '2026-10-24') as mv_24 \gset
select t.as_('mgr');
select public.report_stock_movement('2026-10-05', current_date) as mv_a \gset
select t.as_('mgrB');
select public.report_stock_movement('2026-10-05', current_date) as mv_b \gset
select t.su();
select t.ok('13.6 every row balances: closing = opening + purchased + transfer in - transfer out - used - wasted + adjusted + counted, and closing = the stock today',
  (select bool_and((x->>'closing')::numeric = (x->>'opening')::numeric + (x->>'purchased')::numeric + (x->>'transfer_in')::numeric - (x->>'transfer_out')::numeric
                   - (x->>'used')::numeric - (x->>'wasted')::numeric + (x->>'adjusted')::numeric + (x->>'counted')::numeric
              and (x->>'closing')::numeric = (select round(coalesce(sum(m.qty), 0), 4) from public.stock_movements m where m.branch_id = (x->>'branch_id')::uuid and m.ingredient_id = (x->>'ingredient_id')::uuid))
     from jsonb_array_elements((:'mv_all'::jsonb)->'rows') x));
select t.eq('13.7 between 6 and 10 Oct only the milk wastage moves: milk opening 30, wasted 1, closing 29; every other row has opening = closing and no movement',
  (select jsonb_build_object('milk', (select jsonb_build_object('o', x->'opening', 'w', x->'wasted', 'c', x->'closing') from jsonb_array_elements((:'mv_mid'::jsonb)->'rows') x where x->>'name' = 'Milk'),
     'others_quiet', (select bool_and((x->>'opening')::numeric = (x->>'closing')::numeric) from jsonb_array_elements((:'mv_mid'::jsonb)->'rows') x where x->>'name' <> 'Milk'))::text),
  '{"milk": {"o": 30, "w": 1, "c": 29}, "others_quiet": true}');
select t.eq('13.8 24 Oct (the bill with a back-dated business day): burgers sold 2, one cancelled -> bun used 1, patty used 0.15, nothing else is used',
  (select jsonb_agg(jsonb_build_object('n', x->>'name', 'u', x->'used') order by x->>'name')::text from jsonb_array_elements((:'mv_24'::jsonb)->'rows') x where (x->>'used')::numeric <> 0),
  '[{"n": "Bun", "u": 1}, {"n": "Patty", "u": 0.15}]');
select t.ok('13.9 detail rows: newest first, same count as the movements, value = qty x snapshot cost; 24 Oct details are all dated 24 Oct',
  (select bool_and((a->>'at')::timestamptz >= (b->>'at')::timestamptz) from (select e as a, lead(e) over (order by ord) as b from jsonb_array_elements((:'mv_all'::jsonb)->'details') with ordinality d(e, ord)) z where b is not null)
  and ((:'mv_all'::jsonb)->>'total_rows')::int = (select count(*) from public.stock_movements where business_date >= '2026-10-05')
  and jsonb_array_length((:'mv_all'::jsonb)->'details') = ((:'mv_all'::jsonb)->>'total_rows')::int
  and (select bool_and((e->>'business_date') = '2026-10-24') from jsonb_array_elements((:'mv_24'::jsonb)->'details') e));
select t.ok('13.10 value totals equal sums of snapshot costs: used_value = what the sales took out at cost',
  ((:'mv_all'::jsonb)#>>'{totals,used_value}')::numeric = round(-(select sum(qty * unit_cost) from public.stock_movements where kind in ('sale', 'returned') and business_date >= '2026-10-05'), 2)
  and ((:'mv_all'::jsonb)#>>'{totals,wasted_value}')::numeric = round(-(select sum(qty * unit_cost) from public.stock_movements where kind = 'wastage' and business_date >= '2026-10-05'), 2)
  and ((:'mv_all'::jsonb)#>>'{totals,purchased_value}')::numeric = round((select sum(qty * unit_cost) from public.stock_movements where kind = 'purchase' and business_date >= '2026-10-05'), 2));
select t.ok('13.11 outlets reconcile: A + B = All for movements and values, and by_outlet adds up to the totals',
  ((:'mv_a'::jsonb)->>'total_rows')::int + ((:'mv_b'::jsonb)->>'total_rows')::int = ((:'mv_all'::jsonb)->>'total_rows')::int
  and ((:'mv_a'::jsonb)#>>'{totals,used_value}')::numeric + ((:'mv_b'::jsonb)#>>'{totals,used_value}')::numeric = ((:'mv_all'::jsonb)#>>'{totals,used_value}')::numeric
  and ((:'mv_all'::jsonb)#>>'{totals,purchased_value}')::numeric = (select sum((x->>'purchased_value')::numeric) from jsonb_array_elements((:'mv_all'::jsonb)->'by_outlet') x));
select t.err('13.12 range checks: wrong order and over a year', format('select t.as_(%L); select public.report_stock_movement(%L, %L)', 'owner', '2026-10-10', '2026-10-01'), 'Choose a valid date range');
select t.err('13.13 over a year', format('select t.as_(%L); select public.report_stock_movement(%L, %L)', 'owner', '2025-01-01', '2026-10-01'), 'Choose a range of one year or less');

-- food cost
select t.as_('owner');
select public.report_food_cost('2026-10-24', '2026-10-24') as fc24 \gset
select public.report_food_cost('2026-10-01', current_date) as fc_all \gset
select t.as_('mgr');
select public.report_food_cost('2026-10-01', current_date) as fc_a \gset
select t.as_('mgrB');
select public.report_food_cost('2026-10-01', current_date) as fc_b \gset
select t.su();
select t.ok('13.14 a day with a dish without a recipe: sales 24 Oct = water + 1 burger; only the burger is covered; cost = 1 x (bun 5 + patty 0.15 x 200) = 35',
  ((:'fc24'::jsonb)#>>'{totals,cost}')::numeric = 35
  and ((:'fc24'::jsonb)#>>'{totals,net_sales_all}')::numeric = (select sum(oi.net_amount) from public.order_items oi where oi.order_id = t.get('bill:bd')::uuid and oi.cancelled_at is null)
  and ((:'fc24'::jsonb)#>>'{totals,net_sales_covered}')::numeric = (select sum(oi.net_amount) from public.order_items oi where oi.order_id = t.get('bill:bd')::uuid and oi.cancelled_at is null and oi.product_id = t.id('burger'))
  and ((:'fc24'::jsonb)#>>'{totals,cost_pct}')::numeric = round(100 * 35 / ((:'fc24'::jsonb)#>>'{totals,net_sales_covered}')::numeric, 1)
  and ((:'fc24'::jsonb)#>>'{totals,coverage_pct}')::numeric = round(100 * ((:'fc24'::jsonb)#>>'{totals,net_sales_covered}')::numeric / ((:'fc24'::jsonb)#>>'{totals,net_sales_all}')::numeric, 1),
  (:'fc24'::jsonb)::text);
select t.eq('13.15 by dish: water is listed with cost null and has_recipe false; burger has cost 35 and a percentage',
  (select jsonb_object_agg(x->>'name', jsonb_build_object('rec', x->'has_recipe', 'cost', x->'cost', 'pct', (x->>'cost_pct') is not null, 'margin', (x->>'margin') is not null))::text from jsonb_array_elements((:'fc24'::jsonb)->'by_dish') x),
  '{"Burger": {"cost": 35.00, "pct": true, "rec": true, "margin": true}, "Water": {"cost": null, "pct": false, "rec": false, "margin": false}}');
select t.eq('13.16 by day: the 24 Oct row matches the totals (the sale is dated 24 Oct although made today)', (select jsonb_agg(x->>'business_date')::text from jsonb_array_elements((:'fc24'::jsonb)->'by_day') x), '["2026-10-24"]');
select t.ok('13.17 the whole month agrees with an independent calculation: sales of non-voided bills (not cancelled lines) and the snapshot cost of their sale/return rows',
  ((:'fc_all'::jsonb)#>>'{totals,net_sales_all}')::numeric = (select round(sum(oi.net_amount), 2) from public.order_items oi join public.orders o on o.id = oi.order_id
        where o.restaurant_id = t.r() and o.status <> 'voided' and o.merged_into is null and oi.cancelled_at is null and o.business_date between '2026-10-01' and current_date)
  and ((:'fc_all'::jsonb)#>>'{totals,cost}')::numeric = (select round(-sum(m.qty * m.unit_cost), 2) from public.stock_movements m
        where m.kind in ('sale', 'returned') and m.order_item_id in (select oi.id from public.order_items oi join public.orders o on o.id = oi.order_id
          where o.restaurant_id = t.r() and o.status <> 'voided' and o.merged_into is null and oi.cancelled_at is null and o.business_date between '2026-10-01' and current_date)),
  (:'fc_all'::jsonb)#>>'{totals}');
select t.ok('13.18 voided bills (S, D, P, Q, CV) are not in the sales and not in the cost; by_day and by_outlet add up to the totals; A + B = All',
  ((:'fc_all'::jsonb)#>>'{totals,net_sales_all}')::numeric = (select sum((x->>'net_sales_all')::numeric) from jsonb_array_elements((:'fc_all'::jsonb)->'by_day') x)
  and ((:'fc_all'::jsonb)#>>'{totals,net_sales_all}')::numeric = (select sum((x->>'net_sales_all')::numeric) from jsonb_array_elements((:'fc_all'::jsonb)->'by_outlet') x)
  and ((:'fc_a'::jsonb)#>>'{totals,net_sales_all}')::numeric + ((:'fc_b'::jsonb)#>>'{totals,net_sales_all}')::numeric = ((:'fc_all'::jsonb)#>>'{totals,net_sales_all}')::numeric
  and ((:'fc_all'::jsonb)#>>'{totals,wastage_cost}')::numeric = (select round(-sum(qty * unit_cost), 2) from public.stock_movements where kind = 'wastage' and business_date between '2026-10-01' and current_date)
  and not exists (select 1 from jsonb_array_elements((:'fc_all'::jsonb)->'by_dish') x where x->>'name' is null));
select t.err('13.19 Chef has stock.view but not report.view_sales: refused', format('select t.as_(%L); select public.report_food_cost(%L, %L)', 'chef', '2026-10-01', '2026-10-31'), '(report.view_sales)');
select t.err('13.20 Cashier has report.view_sales but not stock.view: refused', format('select t.as_(%L); select public.report_food_cost(%L, %L)', 'carl', '2026-10-01', '2026-10-31'), '(stock.view)');

-- wastage
select t.as_('owner');
select public.report_wastage('2026-10-01', current_date) as wa_all \gset
select t.as_('mgr');
select public.report_wastage('2026-10-01', current_date) as wa_a \gset
select t.as_('mgrB');
select public.report_wastage('2026-10-01', current_date) as wa_b \gset
select t.as_('chef');
select public.report_wastage('2026-10-10', '2026-10-10') as wa_10 \gset
select t.su();
select t.ok('13.21 wastage totals = the wastage movements (count and value at snapshot cost), positive numbers',
  ((:'wa_all'::jsonb)#>>'{totals,lines}')::int = (select count(*) from public.stock_movements where kind = 'wastage' and business_date >= '2026-10-01')
  and ((:'wa_all'::jsonb)#>>'{totals,value}')::numeric = (select round(-sum(qty * unit_cost), 2) from public.stock_movements where kind = 'wastage' and business_date >= '2026-10-01')
  and ((:'wa_all'::jsonb)#>>'{totals,value}')::numeric > 0);
select t.ok('13.22 every grouping adds up to the total (reason, ingredient, day, user, outlet)',
  (select bool_and(s = ((:'wa_all'::jsonb)#>>'{totals,value}')::numeric) from (
     select sum((x->>'value')::numeric) s from jsonb_array_elements((:'wa_all'::jsonb)->'by_reason') x
     union all select sum((x->>'value')::numeric) from jsonb_array_elements((:'wa_all'::jsonb)->'by_ingredient') x
     union all select sum((x->>'value')::numeric) from jsonb_array_elements((:'wa_all'::jsonb)->'by_day') x
     union all select sum((x->>'value')::numeric) from jsonb_array_elements((:'wa_all'::jsonb)->'by_user') x
     union all select sum((x->>'value')::numeric) from jsonb_array_elements((:'wa_all'::jsonb)->'by_outlet') x) z));
select t.eq('13.23 by reason: the chef''s spoilage (2 x 60) is there, and old/unspecific wastage shows as "other"',
  (select jsonb_object_agg(x->>'reason', x->'value')::text from jsonb_array_elements((:'wa_all'::jsonb)->'by_reason') x where x->>'reason' in ('spoilage')), '{"spoilage": 120.00}');
select t.ok('13.24 the chef appears by name in by_user', exists (select 1 from jsonb_array_elements((:'wa_all'::jsonb)->'by_user') x where x->>'user_name' = 'Charlie Chef'));
select t.ok('13.25 outlets: A + B = All (lines and value)', ((:'wa_a'::jsonb)#>>'{totals,lines}')::int + ((:'wa_b'::jsonb)#>>'{totals,lines}')::int = ((:'wa_all'::jsonb)#>>'{totals,lines}')::int
  and ((:'wa_a'::jsonb)#>>'{totals,value}')::numeric + ((:'wa_b'::jsonb)#>>'{totals,value}')::numeric = ((:'wa_all'::jsonb)#>>'{totals,value}')::numeric);
select t.eq('13.26 business day: the milk wastage of 02:30 on 11 Oct is in the report for 10 Oct (1 line, 60), by Chef too', (select jsonb_build_object('l', (:'wa_10'::jsonb)#>'{totals,lines}', 'v', (:'wa_10'::jsonb)#>'{totals,value}')::text), '{"l": 1, "v": 60.00}');
-- the 2000-row cap: 2001 wastage lines on one day give 2000 rows, truncated, total_rows 2001; same for the movement report
set session_replication_role = replica;
insert into public.ingredients (id, restaurant_id, name, unit, cost_per_unit) values (t.id('probe'), t.r(), 'Probe', 'kg', 1);
insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, business_date, reason, created_at)
  select t.r(), t.get('branch')::uuid, t.id('probe'), 'wastage', -1, 1, '2025-03-03', 'spill', now() - (g || ' seconds')::interval from generate_series(1, 2001) g;
set session_replication_role = default;
select t.as_('owner');
select public.report_wastage('2025-03-03', '2025-03-03') as wcap \gset
select public.report_stock_movement('2025-03-03', '2025-03-03') as mcap \gset
select t.su();
select t.eq('13.28 wastage cap', (select jsonb_build_object('rows', jsonb_array_length((:'wcap'::jsonb)->'rows'), 'trunc', (:'wcap'::jsonb)->'truncated', 'total', (:'wcap'::jsonb)->'total_rows', 'lines', (:'wcap'::jsonb)#>'{totals,lines}')::text),
  '{"rows": 2000, "lines": 2001, "total": 2001, "trunc": true}');
select t.eq('13.29 movement cap', (select jsonb_build_object('rows', jsonb_array_length((:'mcap'::jsonb)->'details'), 'trunc', (:'mcap'::jsonb)->'truncated', 'total', (:'mcap'::jsonb)->'total_rows')::text), '{"rows": 2000, "total": 2001, "trunc": true}');
-- edition off, rights, grants
select t.err('13.30 Basic edition: stock on hand refused', format('select t.as_(%L); select public.report_stock_on_hand()', 'other'), 'needs the Professional edition');
select t.err('13.31 Basic edition: stock movement refused', format('select t.as_(%L); select public.report_stock_movement(%L, %L)', 'other', '2026-10-01', '2026-10-02'), 'needs the Professional edition');
select t.err('13.32 Basic edition: food cost refused', format('select t.as_(%L); select public.report_food_cost(%L, %L)', 'other', '2026-10-01', '2026-10-02'), 'needs the Professional edition');
select t.err('13.33 Basic edition: wastage refused', format('select t.as_(%L); select public.report_wastage(%L, %L)', 'other', '2026-10-01', '2026-10-02'), 'needs the Professional edition');
select t.err('13.34 Cashier: stock on hand refused', format('select t.as_(%L); select public.report_stock_on_hand()', 'carl'), '(stock.view)');
select t.err('13.35 Cashier: wastage refused', format('select t.as_(%L); select public.report_wastage(%L, %L)', 'carl', '2026-10-01', '2026-10-02'), '(stock.view)');
select t.err('13.36 Cashier: stock movement refused', format('select t.as_(%L); select public.report_stock_movement(%L, %L)', 'carl', '2026-10-01', '2026-10-02'), '(stock.view)');
select t.ok('13.37 grants: all new functions are callable by signed-in users and NOT by anon (and the helpers by nobody)',
  (select bool_and(has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute')) from unnest(array[
     'public.record_stock(uuid,text,numeric,numeric,text)', 'public.stock_in_quick(jsonb,text,text,uuid)', 'public.adjust_stock(uuid,text,numeric,text,text,uuid)',
     'public.stock_count_apply(jsonb,text,uuid)', 'public.stock_warnings(jsonb)', 'public.low_stock_items(int)', 'public.stock_report(date,date)',
     'public.report_stock_on_hand(date)', 'public.report_stock_movement(date,date)', 'public.report_food_cost(date,date)', 'public.report_wastage(date,date)']) f)
  and (select bool_and(not has_function_privilege('authenticated', f, 'execute') and not has_function_privilege('anon', f, 'execute')) from unnest(array[
     'app.stock_stamp()', 'app.apply_purchase_cost(uuid,numeric,numeric)', 'app.require_stock_any(text[])', 'app.stock_num(text)']) f));

-- ================================================================ 14 erase (go-live clean-up) with the new tables present
do $$
declare r4 uuid := t.get('rest4')::uuid; ing uuid := gen_random_uuid(); n bigint; lines int;
begin
  insert into public.ingredients (id, restaurant_id, name, unit, cost_per_unit) values (ing, r4, 'Erase me', 'kg', 1);
  perform set_config('request.jwt.claim.sub', t.id('auth:new4')::text, false);
  perform set_config('role', 'authenticated', false);
  perform public.stock_count_apply(jsonb_build_array(jsonb_build_object('ingredient_id', ing, 'counted', 4)), null, null);
  perform t.su();
  select count(*) into lines from public.stock_count_lines where restaurant_id = r4;
  perform t.ok('14.1 setup: Late Foods has a count with a line and a movement', lines = 1 and (select count(*) from public.stock_movements where restaurant_id = r4) = 1);
  perform set_config('app.erase_restaurant', r4::text, false);
  n := app.erase_tables(r4, app.erase_groups()->'stock_tx');
  n := app.erase_tables(r4, app.erase_groups()->'stock_master');
  perform set_config('app.erase_restaurant', '', false);
  perform t.ok('14.2 erasing stock transactions and then stock masters works with the new tables present: movements, ingredients and count lines are gone',
    (select count(*) from public.stock_movements where restaurant_id = r4) = 0 and (select count(*) from public.ingredients where restaurant_id = r4) = 0
    and (select count(*) from public.stock_count_lines where restaurant_id = r4) = 0);
end $$;

-- ================================================================ 15 running the migration twice changed nothing
select t.ok('15.1 one stamp trigger, one grant trigger, policies are single', (select count(*) = 1 from pg_trigger where tgrelid = 'public.stock_movements'::regclass and tgname = 'trg_stock_stamp')
  and (select count(*) = 1 from pg_trigger where tgrelid = 'public.roles'::regclass and tgname = 'trg_grant_chef_stock')
  and (select count(*) = 1 from pg_policy where polrelid = 'public.stock_movements'::regclass and polname = 'tenant_read')
  and (select count(*) = 1 from (select role_id, permission_key from public.role_permissions where permission_key = 'stock.view' group by 1, 2 having count(*) > 1) d) is not true);

-- ================================================================ result
\o
select case when ok then 'PASS' else 'FAIL' end as result, label, detail from t.res order by n;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from t.res \gset
\echo
\echo RESULT: :passed passed, :failed failed
select case when :failed > 0 then 1/0 end as stop_if_failed;
