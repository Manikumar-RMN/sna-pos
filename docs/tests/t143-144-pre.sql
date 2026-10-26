-- t143-144-pre.sql: runs on a database with migrations 001..140 ONLY (before 143). Builds the fixtures shared with t143-144.sql and writes OLD-style
-- stock rows (the way 050 / 093 wrote them: no cost, no business date) so t143-144.sql can prove the 143 back-fill. Test databases only (superuser).
\set ON_ERROR_STOP on
\pset pager off
\o /dev/null
drop schema if exists t cascade;
create schema t;
create table t.res (n serial, ok boolean, label text, detail text);
create table t.kv (k text primary key, v text);
grant usage on schema t to public; grant all on t.res, t.kv to public; grant usage on sequence t.res_n_seq to public;
create function t.id(p text) returns uuid language sql immutable as $$ select md5('t143:' || p)::uuid $$;
create function t.set(p_k text, p_v text) returns void language sql as $$ insert into t.kv values (p_k, p_v) on conflict (k) do update set v = excluded.v $$;
create function t.get(p_k text) returns text language sql stable as $$ select v from t.kv where k = p_k $$;
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
create function t.items(p_spec jsonb) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('product_id', t.id(k), 'qty', v::numeric)) from jsonb_each_text(p_spec) x(k, v) $$;
-- stock of one ingredient at one outlet
create function t.stock(p_ing text, p_branch text default 'branch') returns numeric language sql stable as $$
  select coalesce(sum(qty), 0) from public.stock_movements where ingredient_id = t.id(p_ing) and branch_id = t.get(p_branch)::uuid $$;
-- a running bill on a table as <who>
create function t.bill(p_key text, p_table text, p_items jsonb, p_who text default 'carl') returns uuid language plpgsql as $$
declare v jsonb;
begin
  perform t.as_(p_who);
  v := public.create_order(p_items, 'dine_in', t.id(p_table));
  perform t.su();
  perform t.set('bill:' || p_key, v->>'order_id');
  return (v->>'order_id')::uuid;
end $$;

-- ---------------------------------------------------------------- fixtures
do $$
declare x text; r uuid; b uuid; r2 uuid; cat uuid; tg5 uuid; mg uuid;
begin
  foreach x in array array['owner','mgr','mgrB','carl','chef','stocker','other'] loop
    insert into auth.users (id, email) values (t.id('auth:' || x), x || '@t143.test');
  end loop;
  perform set_config('request.jwt.claim.sub', t.id('auth:owner')::text, false);
  r := public.create_restaurant_with_owner('T143 Foods Pvt Ltd', 'T143 Kitchen', 'IN', 'Olivia Owner', 'Main', 'MN');
  perform set_config('request.jwt.claim.sub', t.id('auth:other')::text, false);
  r2 := public.create_restaurant_with_owner('Basic Foods Pvt Ltd', 'Basic Kitchen', 'IN', 'Other Owner', 'Main', 'MN');
  perform t.set('rest', r::text); perform t.set('rest2', r2::text);
  select id into b from public.branches where restaurant_id = r; perform t.set('branch', b::text);
  update public.restaurants set edition = 'professional' where id = r;
  update public.restaurants set edition = 'basic' where id = r2;
  update public.users set all_outlets = true where id = (select id from public.users where restaurant_id = r and auth_user_id = t.id('auth:owner'));
  insert into public.branches (id, restaurant_id, name, code, country_code, timezone)
    select t.id('branchB'), r, 'Outlet B', 'B', country_code, timezone from public.branches where id = b;
  update public.branches set created_at = now() + interval '1 hour' where id = t.id('branchB');
  perform t.set('branchB', t.id('branchB')::text);
  -- a custom role that has stock.manage BEFORE 143: it must get stock.view / stock.adjust from the migration
  insert into public.roles (id, restaurant_id, name, is_system) values (t.id('roleStocker'), r, 'Stock keeper', false);
  insert into public.role_permissions (role_id, permission_key) values (t.id('roleStocker'), 'stock.manage'), (t.id('roleStocker'), 'order.create');
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    select t.id('u:mgr'), r, t.id('auth:mgr'), 'E2', 'Maya Manager', ro.id, 'mgr@t143.test' from public.roles ro where ro.restaurant_id = r and ro.name = 'Manager';
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    select t.id('u:mgrB'), r, t.id('auth:mgrB'), 'E3', 'Basil Manager', ro.id, 'mgrB@t143.test' from public.roles ro where ro.restaurant_id = r and ro.name = 'Manager';
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    select t.id('u:carl'), r, t.id('auth:carl'), 'E4', 'Carl Cashier', ro.id, 'carl@t143.test' from public.roles ro where ro.restaurant_id = r and ro.name = 'Cashier';
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    select t.id('u:chef'), r, t.id('auth:chef'), 'E5', 'Charlie Chef', ro.id, 'chef@t143.test' from public.roles ro where ro.restaurant_id = r and ro.name = 'Chef';
  insert into public.users (id, restaurant_id, auth_user_id, employee_code, full_name, role_id, email)
    values (t.id('u:stocker'), r, t.id('auth:stocker'), 'E6', 'Stella Stocker', t.id('roleStocker'), 'stocker@t143.test');
  insert into public.user_branches (user_id, branch_id, restaurant_id) values
    (t.id('u:mgr'), b, r), (t.id('u:mgrB'), t.id('branchB'), r), (t.id('u:carl'), b, r), (t.id('u:chef'), b, r), (t.id('u:stocker'), b, r);
  insert into public.dining_tables (id, restaurant_id, branch_id, table_number, seats) values
    (t.id('T1'), r, b, 'T1', 4), (t.id('T2'), r, b, 'T2', 4), (t.id('T3'), r, b, 'T3', 4), (t.id('T4'), r, b, 'T4', 4), (t.id('T5'), r, b, 'T5', 4),
    (t.id('T6'), r, b, 'T6', 4), (t.id('T7'), r, b, 'T7', 4), (t.id('T8'), r, b, 'T8', 4), (t.id('X1'), r, t.id('branchB'), 'X1', 4);
  select id into tg5 from public.tax_groups where restaurant_id = r and name ~ '5\s*%' and name !~ '12|18' order by name limit 1;
  if tg5 is null then select id into tg5 from public.tax_groups where restaurant_id = r order by name limit 1; end if;
  select id into cat from public.categories where restaurant_id = r limit 1;
  if cat is null then insert into public.categories (id, restaurant_id, name, display_order) values (t.id('cat'), r, 'Mains', 1); cat := t.id('cat'); end if;
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price) values
    (t.id('burger'), r, cat, tg5, 'Burger', 100), (t.id('tea'), r, cat, tg5, 'Tea', 20), (t.id('dosa'), r, cat, tg5, 'Dosa', 80),
    (t.id('water'), r, cat, tg5, 'Water', 20);
  insert into public.products (id, restaurant_id, category_id, tax_group_id, name, price, is_combo) values (t.id('meal'), r, cat, tg5, 'Burger Meal', 150, true);
  insert into public.modifier_groups (id, restaurant_id, name, min_select, max_select, is_required) values (t.id('grpDrink'), r, 'Drink', 1, 1, true);
  insert into public.modifier_items (id, restaurant_id, modifier_group_id, name, price_delta, product_id) values (t.id('optTea'), r, t.id('grpDrink'), 'Tea', 0, t.id('tea'));
  insert into public.product_modifier_groups (product_id, modifier_group_id, restaurant_id) values (t.id('meal'), t.id('grpDrink'), r);
  -- ingredients and recipes (direct inserts: the fixture, not the thing under test)
  insert into public.ingredients (id, restaurant_id, name, unit, cost_per_unit, reorder_level) values
    (t.id('bun'), r, 'Bun', 'pcs', 5, 20), (t.id('patty'), r, 'Patty', 'kg', 200, 2), (t.id('milk'), r, 'Milk', 'l', 60, 5),
    (t.id('teapow'), r, 'Tea powder', 'kg', 400, 0.2), (t.id('rice'), r, 'Rice', 'kg', 80, 5);
  insert into public.recipe_lines (restaurant_id, product_id, ingredient_id, qty) values
    (r, t.id('burger'), t.id('bun'), 1), (r, t.id('burger'), t.id('patty'), 0.15),
    (r, t.id('tea'), t.id('milk'), 0.1), (r, t.id('tea'), t.id('teapow'), 0.005),
    (r, t.id('dosa'), t.id('rice'), 0.2);
end $$;

-- ---------------------------------------------------------------- OLD-style stock (record_stock of 050, triggers of 050 / 093)
select t.as_('owner');
select public.record_stock(t.id('bun'), 'purchase', 100, 5);
select public.record_stock(t.id('patty'), 'purchase', 20, 200);
select public.record_stock(t.id('milk'), 'purchase', 30, 60);
select public.record_stock(t.id('teapow'), 'purchase', 2, 400);
select public.record_stock(t.id('rice'), 'purchase', 3, 80);
select public.record_stock(t.id('milk'), 'wastage', 1, null, 'spilled before 143');
select t.su();
select t.bill('old1', 'T1', t.items('{"burger":2,"tea":1}'));
select t.bill('old2', 'T2', t.items('{"dosa":1}'));
select t.set('old_cost_burger_bun', (select cost_per_unit::text from public.ingredients where id = t.id('bun')));
-- back-date: the milk wastage happened at 02:30 local time (21:00 UTC) on 11 Oct = business day 10 Oct (4 a.m. cut-off); the purchases on 5 Oct
set session_replication_role = replica;
update public.stock_movements set created_at = '2026-10-10 21:00+00' where kind = 'wastage' and ingredient_id = t.id('milk');
update public.stock_movements set created_at = '2026-10-05 06:00+00' where kind = 'purchase';
set session_replication_role = default;

-- "before 143" figures: stock level and cost of each ingredient as the old Stock screen shows them
select t.as_('owner');
select t.set('before_levels', (select jsonb_agg(jsonb_build_object('name', x->>'name', 'stock', x->'stock', 'cost', x->'cost') order by x->>'name')::text
  from jsonb_array_elements(public.stock_report('2026-01-01', '2026-12-31')->'levels') x));
select t.su();
select t.set('before_rows', (select count(*)::text from public.stock_movements));
select t.set('before_null_cost_sale', (select count(*)::text from public.stock_movements where kind = 'sale' and unit_cost is null));
select t.set('order_bd_old1', (select business_date::text from public.orders where id = t.get('bill:old1')::uuid));
