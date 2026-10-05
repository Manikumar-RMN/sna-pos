-- 079: suppliers and purchasing (part of the Stock module, Professional)
--
-- What an owner does with it:
--   1. keeps a list of suppliers;
--   2. writes a purchase order (optionally straight from the low-stock list);
--   3. receives the goods -- against the order or without one -- which puts the
--      quantities into stock and updates each ingredient's cost exactly as a
--      manual "purchase" on the Stock screen does;
--   4. records what was paid to the supplier and sees what is still owed.
--
-- Uses the existing right "Stock, purchases and recipes" (stock.manage). Every
-- write goes through the functions below; signed-in people can only read.

------------------------------------------------------------------
-- Tables
------------------------------------------------------------------
create table if not exists public.suppliers (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name          text not null check (length(trim(name)) between 1 and 80),
  contact_person text,
  phone         text,
  email         text,
  tax_no        text,
  address       text,
  payment_days  integer not null default 0 check (payment_days between 0 and 365),
  notes         text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (restaurant_id, id)
);
create unique index if not exists suppliers_name_uq on public.suppliers (restaurant_id, lower(trim(name))) where is_active;

create table if not exists public.purchase_orders (
  id            uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id     uuid not null,
  supplier_id   uuid not null,
  number        text not null,
  status        text not null default 'draft' check (status in ('draft', 'ordered', 'part_received', 'received', 'cancelled')),
  expected_on   date,
  notes         text,
  total         numeric(14,2) not null default 0 check (total >= 0),
  created_by    uuid not null references public.users(id),
  created_at    timestamptz not null default now(),
  ordered_at    timestamptz,
  closed_at     timestamptz,
  unique (branch_id, number),
  unique (restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, supplier_id) references public.suppliers(restaurant_id, id)
);
create index if not exists purchase_orders_lookup on public.purchase_orders (branch_id, status, created_at desc);

create table if not exists public.purchase_order_lines (
  id                uuid primary key default gen_random_uuid(),
  restaurant_id     uuid not null,
  purchase_order_id uuid not null,
  ingredient_id     uuid not null,
  qty               numeric(14,3) not null check (qty > 0),
  unit_cost         numeric(14,4) not null default 0 check (unit_cost >= 0),
  received_qty      numeric(14,3) not null default 0 check (received_qty >= 0),
  unique (purchase_order_id, ingredient_id),
  foreign key (restaurant_id, purchase_order_id) references public.purchase_orders(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id)
);

create table if not exists public.goods_receipts (
  id                 uuid primary key default gen_random_uuid(),
  restaurant_id      uuid not null references public.restaurants(id) on delete cascade,
  branch_id          uuid not null,
  supplier_id        uuid not null,
  purchase_order_id  uuid,
  number             text not null,
  supplier_bill_no   text,
  supplier_bill_date date,
  received_on        date not null,
  subtotal           numeric(14,2) not null default 0,
  tax_amount         numeric(14,2) not null default 0 check (tax_amount >= 0),
  other_charges      numeric(14,2) not null default 0 check (other_charges >= 0),
  total              numeric(14,2) not null default 0,
  paid_total         numeric(14,2) not null default 0 check (paid_total >= 0),
  payment_status     text not null default 'unpaid' check (payment_status in ('unpaid', 'partial', 'paid')),
  due_on             date,
  notes              text,
  status             text not null default 'received' check (status in ('received', 'cancelled')),
  cancelled_at       timestamptz,
  cancelled_by       uuid references public.users(id),
  cancel_reason      text,
  received_by        uuid not null references public.users(id),
  created_at         timestamptz not null default now(),
  client_ref         uuid,
  unique (branch_id, number),
  unique (restaurant_id, id),
  check (paid_total <= total),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, supplier_id) references public.suppliers(restaurant_id, id),
  foreign key (restaurant_id, purchase_order_id) references public.purchase_orders(restaurant_id, id)
);
create unique index if not exists goods_receipts_client_ref_uq on public.goods_receipts (restaurant_id, client_ref) where client_ref is not null;
create index if not exists goods_receipts_lookup on public.goods_receipts (branch_id, received_on desc);
create index if not exists goods_receipts_supplier on public.goods_receipts (supplier_id, payment_status);

create table if not exists public.goods_receipt_lines (
  id               uuid primary key default gen_random_uuid(),
  restaurant_id    uuid not null,
  goods_receipt_id uuid not null,
  ingredient_id    uuid not null,
  qty              numeric(14,3) not null check (qty > 0),
  unit_cost        numeric(14,4) not null check (unit_cost >= 0),
  line_total       numeric(14,2) not null,
  -- The ingredient's cost just before and just after this delivery, so that
  -- cancelling the delivery can put the old cost back.
  prev_cost        numeric(14,4),
  new_cost         numeric(14,4),
  foreign key (restaurant_id, goods_receipt_id) references public.goods_receipts(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id)
);
create index if not exists goods_receipt_lines_receipt on public.goods_receipt_lines (goods_receipt_id);

create table if not exists public.supplier_payments (
  id               uuid primary key default gen_random_uuid(),
  restaurant_id    uuid not null references public.restaurants(id) on delete cascade,
  branch_id        uuid not null,
  supplier_id      uuid not null,
  goods_receipt_id uuid not null,
  -- A payment is positive. Undoing one adds a matching negative entry; nothing is ever edited.
  amount           numeric(14,2) not null check (amount <> 0),
  method           text not null check (method in ('cash', 'bank', 'upi', 'cheque', 'card', 'other')),
  reference        text,
  paid_on          date not null,
  from_till        boolean not null default false,
  cash_movement_id uuid,
  paid_by          uuid not null references public.users(id),
  created_at       timestamptz not null default now(),
  client_ref       uuid,
  reverses_id      uuid references public.supplier_payments(id),
  reason           text,
  check ((reverses_id is null and amount > 0) or (reverses_id is not null and amount < 0)),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id),
  foreign key (restaurant_id, supplier_id) references public.suppliers(restaurant_id, id),
  foreign key (restaurant_id, goods_receipt_id) references public.goods_receipts(restaurant_id, id)
);
create index if not exists supplier_payments_receipt on public.supplier_payments (goods_receipt_id);
create unique index if not exists supplier_payments_client_ref_uq on public.supplier_payments (restaurant_id, client_ref) where client_ref is not null;
-- A payment can be undone once.
create unique index if not exists supplier_payments_reverses_uq on public.supplier_payments (reverses_id) where reverses_id is not null;

alter table public.stock_movements add column if not exists goods_receipt_id uuid;
alter table public.ingredients add column if not exists category text;

-- Reading: people with the "Stock, purchases and recipes" right, in their own
-- restaurant; orders, receipts and payments only for the outlet they are working
-- in, and the lines of an order or receipt only when they can see its header.
-- No direct writes for anyone.
do $$
declare t text; v_using text;
begin
  foreach t in array array['suppliers', 'purchase_orders', 'purchase_order_lines', 'goods_receipts', 'goods_receipt_lines', 'supplier_payments'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists tenant_read on public.%I', t);
    v_using := 'restaurant_id = (select app.current_restaurant_id()) and (select app.has_permission(''stock.manage''))';
    if t in ('purchase_orders', 'goods_receipts', 'supplier_payments') then
      v_using := v_using || ' and branch_id = (select app.current_branch_id())';
    elsif t = 'purchase_order_lines' then
      v_using := v_using || ' and exists (select 1 from public.purchase_orders h where h.id = purchase_order_id)';
    elsif t = 'goods_receipt_lines' then
      v_using := v_using || ' and exists (select 1 from public.goods_receipts h where h.id = goods_receipt_id)';
    end if;
    execute format('create policy tenant_read on public.%I for select to authenticated using (%s)', t, v_using);
  end loop;
end $$;

-- Money already paid out cannot be edited or removed.
drop trigger if exists trg_no_update_supplier_payments on public.supplier_payments;
create trigger trg_no_update_supplier_payments before update on public.supplier_payments for each row execute function app.block_update();
drop trigger if exists trg_no_delete_supplier_payments on public.supplier_payments;
create trigger trg_no_delete_supplier_payments before delete on public.supplier_payments for each row execute function app.block_delete();

update public.modules set description = 'Ingredients, recipes, suppliers, purchase orders, goods received, wastage, food cost'
 where key = 'stock';

------------------------------------------------------------------
-- Ingredients: material group
------------------------------------------------------------------
drop function if exists public.save_ingredient(uuid, text, text, numeric, numeric);
CREATE OR REPLACE FUNCTION public.save_ingredient(p_id uuid, p_name text, p_unit text, p_cost numeric, p_reorder numeric, p_category text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid;
begin
  perform app.require_feature('stock');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the ingredient name.'; end if;
  if exists (select 1 from public.ingredients where restaurant_id = v_rest and is_active and lower(trim(name)) = lower(trim(p_name)) and id is distinct from p_id) then
    raise exception 'An ingredient called % already exists.', trim(p_name);
  end if;
  if p_id is null then
    insert into public.ingredients (restaurant_id, name, unit, cost_per_unit, reorder_level, category)
    values (v_rest, left(trim(p_name), 60), p_unit, coalesce(p_cost, 0), coalesce(p_reorder, 0), nullif(left(trim(coalesce(p_category, '')), 40), '')) returning id into v_id;
  else
    update public.ingredients set name = left(trim(p_name), 60), unit = p_unit, cost_per_unit = coalesce(p_cost, 0), reorder_level = coalesce(p_reorder, 0),
           category = nullif(left(trim(coalesce(p_category, '')), 40), '')
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'Ingredient not found.'; end if;
  end if;
  perform app.audit('stock.ingredient', 'ingredients', v_id, jsonb_build_object('name', p_name, 'unit', p_unit, 'cost', p_cost, 'reorder', p_reorder));
  return v_id;
end $function$;
revoke all on function public.save_ingredient(uuid, text, text, numeric, numeric, text) from public, anon;
grant execute on function public.save_ingredient(uuid, text, text, numeric, numeric, text) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.stock_report(p_from date, p_to date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_rest uuid; v_branch uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_levels jsonb; v_costs jsonb;
begin
  perform app.require_feature('stock');
  perform app.require_permission('stock.manage');
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz; v_end := (p_to + 1)::timestamp at time zone v_tz;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_levels from (
    select jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost', i.cost_per_unit, 'reorder', i.reorder_level, 'category', i.category,
      'stock', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id), 0),
      'used', -coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind in ('sale', 'returned') and m.created_at >= v_start and m.created_at < v_end), 0),
      'wasted', -coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind = 'wastage' and m.created_at >= v_start and m.created_at < v_end), 0),
      'bought', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind = 'purchase' and m.created_at >= v_start and m.created_at < v_end), 0),
      'transfers', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id and m.kind in ('transfer_in', 'transfer_out') and m.created_at >= v_start and m.created_at < v_end), 0),
      'count_diff', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind = 'count' and m.created_at >= v_start and m.created_at < v_end), 0)) x
      from public.ingredients i where i.restaurant_id = v_rest and i.is_active) z;
  select coalesce(jsonb_agg(x order by (x->>'cost_pct')::numeric desc nulls last), '[]'::jsonb) into v_costs from (
    select jsonb_build_object('product', p.name, 'price', p.price,
      'cost', round(sum(rl.qty * i.cost_per_unit), 2),
      'cost_pct', case when p.price > 0 then round(100 * sum(rl.qty * i.cost_per_unit) / p.price, 1) end) x
      from public.products p join public.recipe_lines rl on rl.product_id = p.id join public.ingredients i on i.id = rl.ingredient_id
     where p.restaurant_id = v_rest and p.deleted_at is null group by p.id, p.name, p.price) z;
  return jsonb_build_object('levels', v_levels, 'food_cost', v_costs);
end $function$;

------------------------------------------------------------------
-- Suppliers
------------------------------------------------------------------
create or replace function public.save_supplier(p_id uuid, p jsonb)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id();
  v_name text := left(trim(coalesce(p->>'name', '')), 80);
  v_days int := coalesce(nullif(trim(coalesce(p->>'payment_days', '')), '')::int, 0);
  v_active boolean := coalesce((p->>'is_active')::boolean, true);
  v_id uuid;
begin
  perform app.require_feature('stock');
  if v_name = '' then raise exception 'Enter the supplier''s name.'; end if;
  if v_days < 0 or v_days > 365 then raise exception 'Payment days must be between 0 and 365.'; end if;
  if v_active and exists (select 1 from public.suppliers s where s.restaurant_id = v_rest and s.is_active
                             and lower(trim(s.name)) = lower(v_name) and s.id is distinct from p_id) then
    raise exception 'A supplier called % already exists.', v_name;
  end if;
  if p_id is null then
    insert into public.suppliers (restaurant_id, name, contact_person, phone, email, tax_no, address, payment_days, notes, is_active)
    values (v_rest, v_name,
            nullif(left(trim(coalesce(p->>'contact_person', '')), 80), ''),
            nullif(left(trim(coalesce(p->>'phone', '')), 30), ''),
            nullif(left(trim(coalesce(p->>'email', '')), 120), ''),
            upper(nullif(left(trim(coalesce(p->>'tax_no', '')), 30), '')),
            nullif(left(trim(coalesce(p->>'address', '')), 300), ''),
            v_days,
            nullif(left(trim(coalesce(p->>'notes', '')), 300), ''),
            v_active)
    returning id into v_id;
  else
    update public.suppliers set
           name = v_name,
           contact_person = nullif(left(trim(coalesce(p->>'contact_person', '')), 80), ''),
           phone = nullif(left(trim(coalesce(p->>'phone', '')), 30), ''),
           email = nullif(left(trim(coalesce(p->>'email', '')), 120), ''),
           tax_no = upper(nullif(left(trim(coalesce(p->>'tax_no', '')), 30), '')),
           address = nullif(left(trim(coalesce(p->>'address', '')), 300), ''),
           payment_days = v_days,
           notes = nullif(left(trim(coalesce(p->>'notes', '')), 300), ''),
           is_active = v_active
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'Supplier not found.'; end if;
  end if;
  perform app.audit('supplier.save', 'suppliers', v_id, jsonb_build_object('name', v_name, 'is_active', v_active));
  return v_id;
end $$;

------------------------------------------------------------------
-- Purchase orders
------------------------------------------------------------------
create or replace function app.purchase_lines(p_rest uuid, p_lines jsonb)
returns table (ingredient_id uuid, qty numeric, unit_cost numeric)
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare l jsonb; v_ing public.ingredients%rowtype; v_seen uuid[] := '{}';
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one ingredient.';
  end if;
  if jsonb_array_length(p_lines) > 200 then raise exception 'Too many lines. Split it into two.'; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce(l->>'ingredient_id', '') !~* '^[0-9a-f-]{36}$' then raise exception 'An ingredient on the list no longer exists.'; end if;
    select * into v_ing from public.ingredients i where i.id = (l->>'ingredient_id')::uuid and i.restaurant_id = p_rest and i.is_active;
    if not found then raise exception 'An ingredient on the list no longer exists.'; end if;
    if v_ing.id = any(v_seen) then raise exception '% is on the list twice. Put it on one line.', v_ing.name; end if;
    v_seen := v_seen || v_ing.id;
    qty := round(coalesce((l->>'qty')::numeric, 0), 3);
    unit_cost := round(coalesce((l->>'unit_cost')::numeric, v_ing.cost_per_unit, 0), 4);
    if qty <= 0 then raise exception 'Enter a quantity for %.', v_ing.name; end if;
    if qty > 1000000 then raise exception 'The quantity for % is too large.', v_ing.name; end if;
    if unit_cost < 0 then raise exception 'The cost of % cannot be negative.', v_ing.name; end if;
    ingredient_id := v_ing.id;
    return next;
  end loop;
end $$;
revoke all on function app.purchase_lines(uuid, jsonb) from public, anon, authenticated;

create or replace function public.save_purchase_order(p_id uuid, p_supplier_id uuid, p_lines jsonb,
                                                      p_expected_on date default null, p_notes text default null,
                                                      p_place boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  po public.purchase_orders%rowtype; v_id uuid := p_id; v_no text; v_seq int; v_total numeric(14,2);
begin
  perform app.require_feature('stock');
  if not exists (select 1 from public.suppliers s where s.id = p_supplier_id and s.restaurant_id = v_rest and s.is_active) then
    raise exception 'Choose a supplier.';
  end if;
  if v_id is null then
    perform pg_advisory_xact_lock(hashtext('purchase_order:' || v_branch::text));
    select count(*) + 1 into v_seq from public.purchase_orders where branch_id = v_branch;
    v_no := 'PO-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');
    v_id := gen_random_uuid();
    insert into public.purchase_orders (id, restaurant_id, branch_id, supplier_id, number, expected_on, notes, created_by)
    values (v_id, v_rest, v_branch, p_supplier_id, v_no, p_expected_on, nullif(left(trim(coalesce(p_notes, '')), 300), ''), v_user);
  else
    select * into po from public.purchase_orders where id = v_id and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'Purchase order not found.'; end if;
    if po.status <> 'draft' then
      raise exception 'Purchase order % has already been sent, so it cannot be changed. Cancel it and write a new one.', po.number;
    end if;
    v_no := po.number;
    update public.purchase_orders set supplier_id = p_supplier_id, expected_on = p_expected_on,
           notes = nullif(left(trim(coalesce(p_notes, '')), 300), '') where id = v_id;
    delete from public.purchase_order_lines where purchase_order_id = v_id;
  end if;
  insert into public.purchase_order_lines (restaurant_id, purchase_order_id, ingredient_id, qty, unit_cost)
  select v_rest, v_id, l.ingredient_id, l.qty, l.unit_cost from app.purchase_lines(v_rest, p_lines) l;
  select coalesce(sum(round(qty * unit_cost, 2)), 0) into v_total from public.purchase_order_lines where purchase_order_id = v_id;
  update public.purchase_orders set total = v_total,
         status = case when p_place then 'ordered' else 'draft' end,
         ordered_at = case when p_place then now() else null end
   where id = v_id;
  perform app.audit('purchase_order.save', 'purchase_orders', v_id,
    jsonb_build_object('number', v_no, 'total', v_total, 'placed', coalesce(p_place, false)));
  return jsonb_build_object('id', v_id, 'number', v_no, 'total', v_total, 'status', case when p_place then 'ordered' else 'draft' end);
end $$;

create or replace function public.set_purchase_order_status(p_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  po public.purchase_orders%rowtype; v_new text;
begin
  perform app.require_feature('stock');
  select * into po from public.purchase_orders
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Purchase order not found.'; end if;
  if p_action = 'order' then
    if po.status <> 'draft' then raise exception 'Purchase order % has already been sent.', po.number; end if;
    v_new := 'ordered';
  elsif p_action = 'cancel' then
    if po.status not in ('draft', 'ordered') then
      raise exception 'Purchase order % already has goods received. Use "No more coming" to close it instead.', po.number;
    end if;
    v_new := 'cancelled';
  elsif p_action = 'close' then
    if po.status <> 'part_received' then raise exception 'Only a part-received order can be closed this way.'; end if;
    v_new := 'received';
  else
    raise exception 'Unknown action.';
  end if;
  update public.purchase_orders set status = v_new,
         ordered_at = case when v_new = 'ordered' then now() else ordered_at end,
         closed_at = case when v_new in ('cancelled', 'received') then now() else closed_at end
   where id = po.id;
  perform app.audit('purchase_order.' || p_action, 'purchase_orders', po.id, jsonb_build_object('number', po.number, 'status', v_new),
                    jsonb_build_object('status', po.status));
  return jsonb_build_object('id', po.id, 'number', po.number, 'status', v_new);
end $$;

------------------------------------------------------------------
-- Paying a supplier (also used when goods are paid for on arrival)
------------------------------------------------------------------
drop function if exists app.pay_goods_receipt(uuid, numeric, text, text, date, boolean, uuid);
create or replace function app.pay_goods_receipt(p_receipt uuid, p_amount numeric, p_method text, p_reference text,
                                                 p_paid_on date, p_from_till boolean, p_user uuid, p_client_ref uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  g public.goods_receipts%rowtype; v_amount numeric(14,2) := round(coalesce(p_amount, 0), 2);
  v_left numeric(14,2); v_shift uuid; v_move uuid; v_sup text; v_id uuid := gen_random_uuid(); v_today date;
begin
  select * into g from public.goods_receipts where id = p_receipt for update;
  if not found then raise exception 'Goods receipt not found.'; end if;
  if g.status = 'cancelled' then raise exception 'Receipt % was cancelled.', g.number; end if;
  if coalesce(p_method, '') not in ('cash', 'bank', 'upi', 'cheque', 'card', 'other') then
    raise exception 'Choose how the supplier was paid.';
  end if;
  v_left := g.total - g.paid_total;
  if v_left <= 0 then raise exception 'Receipt % is already fully paid.', g.number; end if;
  if v_amount <= 0 then raise exception 'Enter an amount greater than zero.'; end if;
  if v_amount > v_left then raise exception 'Only % is still owed on receipt %.', v_left, g.number; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = g.restaurant_id))::date;
  if p_paid_on is not null and p_paid_on > v_today then raise exception 'The payment date cannot be in the future.'; end if;
  select name into v_sup from public.suppliers where id = g.supplier_id;

  if coalesce(p_from_till, false) then
    if p_method <> 'cash' then raise exception 'Only a cash payment can come out of the till.'; end if;
    if not app.allowed('cash.movement') then
      raise exception 'Your role does not allow this action (cash.movement).';
    end if;
    select id into v_shift from public.shifts where branch_id = g.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(g.branch_id); end if;
    if v_shift is null then raise exception 'Open a shift before paying a supplier from the till.'; end if;
    v_move := gen_random_uuid();
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_move, g.restaurant_id, v_shift, 'out', v_amount, left('Paid supplier ' || v_sup || ' (' || g.number || ')', 200), p_user);
  end if;

  insert into public.supplier_payments (id, restaurant_id, branch_id, supplier_id, goods_receipt_id, amount, method, reference,
                                        paid_on, from_till, cash_movement_id, paid_by, client_ref)
  values (v_id, g.restaurant_id, g.branch_id, g.supplier_id, g.id, v_amount, p_method,
          nullif(left(trim(coalesce(p_reference, '')), 60), ''), coalesce(p_paid_on, v_today),
          coalesce(p_from_till, false), v_move, p_user, p_client_ref);
  update public.goods_receipts set paid_total = paid_total + v_amount,
         payment_status = case when paid_total + v_amount >= total then 'paid' else 'partial' end
   where id = g.id;
  perform app.audit('supplier.pay', 'goods_receipts', g.id,
    jsonb_build_object('number', g.number, 'supplier', v_sup, 'amount', v_amount, 'method', p_method, 'from_till', coalesce(p_from_till, false)));
  return jsonb_build_object('payment_id', v_id, 'amount', v_amount, 'balance', v_left - v_amount, 'paid', v_left - v_amount = 0);
end $$;
revoke all on function app.pay_goods_receipt(uuid, numeric, text, text, date, boolean, uuid, uuid) from public, anon, authenticated;

drop function if exists public.pay_supplier(uuid, numeric, text, text, date, boolean);
create or replace function public.pay_supplier(p_receipt_id uuid, p_amount numeric, p_method text,
                                               p_reference text default null, p_paid_on date default null,
                                               p_from_till boolean default false, p_client_ref uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_user uuid := app.require_permission('stock.manage'); v_seen jsonb;
begin
  perform app.require_feature('stock');
  if not exists (select 1 from public.goods_receipts g where g.id = p_receipt_id
                    and g.restaurant_id = app.current_restaurant_id() and g.branch_id = app.current_branch_id()) then
    raise exception 'Goods receipt not found.';
  end if;
  -- The same request sent twice (a second tap, a retry on a bad connection) pays once.
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('supplier_pay_ref:' || p_client_ref::text));
    select jsonb_build_object('payment_id', sp.id, 'amount', sp.amount, 'balance', g.total - g.paid_total,
                              'paid', g.total - g.paid_total = 0, 'repeat', true)
      into v_seen
      from public.supplier_payments sp join public.goods_receipts g on g.id = sp.goods_receipt_id
     where sp.restaurant_id = app.current_restaurant_id() and sp.client_ref = p_client_ref;
    if v_seen is not null then
      if not exists (select 1 from public.supplier_payments sp where sp.restaurant_id = app.current_restaurant_id()
                        and sp.client_ref = p_client_ref and sp.goods_receipt_id = p_receipt_id) then
        raise exception 'This request was already used for another receipt. Close the form, open it again and try once more.';
      end if;
      return v_seen;
    end if;
  end if;
  return app.pay_goods_receipt(p_receipt_id, p_amount, p_method, p_reference, p_paid_on, p_from_till, v_user, p_client_ref);
end $$;

------------------------------------------------------------------
-- Undoing a supplier payment that was entered wrongly
------------------------------------------------------------------
create or replace function public.undo_supplier_payment(p_payment_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  sp public.supplier_payments%rowtype; g public.goods_receipts%rowtype;
  v_shift uuid; v_move uuid; v_sup text; v_id uuid := gen_random_uuid(); v_today date; v_paid numeric(14,2);
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for undoing the payment.'; end if;
  select * into sp from public.supplier_payments
   where id = p_payment_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id();
  if not found then raise exception 'Payment not found.'; end if;
  -- The receipt row is the lock for everything that changes what is owed on it.
  select * into g from public.goods_receipts where id = sp.goods_receipt_id for update;
  if sp.reverses_id is not null then raise exception 'That entry is itself an undo; it cannot be undone.'; end if;
  if exists (select 1 from public.supplier_payments x where x.reverses_id = sp.id) then
    raise exception 'That payment has already been undone.';
  end if;
  select name into v_sup from public.suppliers where id = g.supplier_id;
  v_today := (now() at time zone (select timezone from public.restaurants where id = g.restaurant_id))::date;

  -- Cash that left the till for this payment comes back into the drawer that is open now.
  if sp.from_till then
    if not app.allowed('cash.movement') then
      raise exception 'Your role does not allow this action (cash.movement).';
    end if;
    select id into v_shift from public.shifts where branch_id = g.branch_id and status = 'open' limit 1;
    if v_shift is null then v_shift := app.auto_shift(g.branch_id); end if;
    if v_shift is null then raise exception 'Open a shift before undoing a payment that was made from the till.'; end if;
    v_move := gen_random_uuid();
    insert into public.cash_movements (id, restaurant_id, shift_id, direction, amount, reason, recorded_by)
    values (v_move, g.restaurant_id, v_shift, 'in', sp.amount,
            left('Supplier payment undone: ' || v_sup || ' (' || g.number || ')', 200), v_user);
  end if;

  insert into public.supplier_payments (id, restaurant_id, branch_id, supplier_id, goods_receipt_id, amount, method, reference,
                                        paid_on, from_till, cash_movement_id, paid_by, reverses_id, reason)
  values (v_id, sp.restaurant_id, sp.branch_id, sp.supplier_id, sp.goods_receipt_id, -sp.amount, sp.method, sp.reference,
          v_today, sp.from_till, v_move, v_user, sp.id, left(trim(p_reason), 300));
  v_paid := greatest(0, g.paid_total - sp.amount);
  update public.goods_receipts set paid_total = v_paid,
         payment_status = case when v_paid <= 0 then (case when total = 0 then 'paid' else 'unpaid' end)
                               when v_paid >= total then 'paid' else 'partial' end
   where id = g.id;
  perform app.audit('supplier.pay_undo', 'goods_receipts', g.id,
    jsonb_build_object('number', g.number, 'supplier', v_sup, 'amount', sp.amount, 'method', sp.method,
                       'from_till', sp.from_till, 'reason', left(trim(p_reason), 300)));
  return jsonb_build_object('payment_id', v_id, 'amount', sp.amount, 'balance', g.total - v_paid, 'number', g.number);
end $$;

------------------------------------------------------------------
-- Receiving goods
------------------------------------------------------------------
create or replace function public.receive_goods(p_supplier_id uuid, p_lines jsonb,
                                                p_purchase_order_id uuid default null,
                                                p_bill_no text default null, p_bill_date date default null,
                                                p_tax numeric default 0, p_other numeric default 0,
                                                p_due_on date default null, p_notes text default null,
                                                p_payment jsonb default null, p_client_ref uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  v_rest uuid := app.current_restaurant_id();
  v_branch uuid := app.current_branch_id();
  sup public.suppliers%rowtype; po public.purchase_orders%rowtype; l record;
  v_id uuid := gen_random_uuid(); v_no text; v_seq int; v_today date; v_now numeric;
  v_sub numeric(14,2) := 0; v_tax numeric(14,2) := round(coalesce(p_tax, 0), 2); v_other numeric(14,2) := round(coalesce(p_other, 0), 2);
  v_total numeric(14,2); v_pay jsonb; v_out jsonb; v_po_status text; v_prev_cost numeric; v_new_cost numeric;
begin
  perform app.require_feature('stock');
  if p_client_ref is not null then
    perform pg_advisory_xact_lock(hashtext('grn_ref:' || p_client_ref::text));
    select jsonb_build_object('id', g.id, 'number', g.number, 'total', g.total, 'balance', g.total - g.paid_total, 'repeat', true)
      into v_out from public.goods_receipts g where g.restaurant_id = v_rest and g.client_ref = p_client_ref;
    if v_out is not null then return v_out; end if;
  end if;
  select * into sup from public.suppliers where id = p_supplier_id and restaurant_id = v_rest and is_active;
  if not found then raise exception 'Choose a supplier.'; end if;
  if v_tax < 0 or v_other < 0 then raise exception 'Tax and other charges cannot be negative.'; end if;
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;
  if p_bill_date is not null and p_bill_date > v_today then raise exception 'The supplier''s bill date cannot be in the future.'; end if;

  if p_purchase_order_id is not null then
    select * into po from public.purchase_orders where id = p_purchase_order_id and restaurant_id = v_rest and branch_id = v_branch for update;
    if not found then raise exception 'Purchase order not found.'; end if;
    if po.supplier_id <> sup.id then raise exception 'Purchase order % is for another supplier.', po.number; end if;
    if po.status not in ('ordered', 'part_received') then
      raise exception 'Purchase order % is %, so goods cannot be received against it.', po.number, replace(po.status, '_', ' ');
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtext('goods_receipt:' || v_branch::text));
  select count(*) + 1 into v_seq from public.goods_receipts where branch_id = v_branch;
  v_no := 'GRN-' || (select code from public.branches where id = v_branch) || '-' || lpad(v_seq::text, 4, '0');

  insert into public.goods_receipts (id, restaurant_id, branch_id, supplier_id, purchase_order_id, number, supplier_bill_no,
                                     supplier_bill_date, received_on, due_on, notes, received_by, client_ref)
  values (v_id, v_rest, v_branch, sup.id, po.id, v_no, nullif(left(trim(coalesce(p_bill_no, '')), 40), ''), p_bill_date, v_today,
          coalesce(p_due_on, coalesce(p_bill_date, v_today) + sup.payment_days),
          nullif(left(trim(coalesce(p_notes, '')), 300), ''), v_user, p_client_ref);

  -- Fixed order, so two people receiving at once cannot block each other.
  for l in select * from app.purchase_lines(v_rest, p_lines) x order by x.ingredient_id loop
    perform pg_advisory_xact_lock(hashtext('stock:' || v_branch::text || ':' || l.ingredient_id::text));
    select coalesce(sum(m.qty), 0) into v_now from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = l.ingredient_id;
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, goods_receipt_id)
    values (v_rest, v_branch, l.ingredient_id, 'purchase', l.qty, l.unit_cost, left(v_no || ' · ' || sup.name, 200), v_user, v_id);
    -- Same rule as a purchase on the Stock screen: the new price is weighted with the stock already held.
    select i.cost_per_unit into v_prev_cost from public.ingredients i where i.id = l.ingredient_id;
    update public.ingredients i set cost_per_unit = case when v_now > 0
             then round((v_now * i.cost_per_unit + l.qty * l.unit_cost) / (v_now + l.qty), 4) else l.unit_cost end
     where i.id = l.ingredient_id
    returning i.cost_per_unit into v_new_cost;
    insert into public.goods_receipt_lines (restaurant_id, goods_receipt_id, ingredient_id, qty, unit_cost, line_total, prev_cost, new_cost)
    values (v_rest, v_id, l.ingredient_id, l.qty, l.unit_cost, round(l.qty * l.unit_cost, 2), v_prev_cost, v_new_cost);
    v_sub := v_sub + round(l.qty * l.unit_cost, 2);
    if po.id is not null then
      update public.purchase_order_lines set received_qty = received_qty + l.qty
       where purchase_order_id = po.id and ingredient_id = l.ingredient_id;
    end if;
  end loop;

  v_total := v_sub + v_tax + v_other;
  update public.goods_receipts set subtotal = v_sub, tax_amount = v_tax, other_charges = v_other, total = v_total,
         payment_status = case when v_total = 0 then 'paid' else 'unpaid' end
   where id = v_id;

  if po.id is not null then
    v_po_status := case when exists (select 1 from public.purchase_order_lines where purchase_order_id = po.id and received_qty < qty)
                        then 'part_received' else 'received' end;
    update public.purchase_orders set status = v_po_status,
           closed_at = case when v_po_status = 'received' then now() else null end
     where id = po.id;
  end if;

  perform app.audit('goods.receive', 'goods_receipts', v_id,
    jsonb_build_object('number', v_no, 'supplier', sup.name, 'total', v_total, 'purchase_order', po.number));

  if p_payment is not null and jsonb_typeof(p_payment) = 'object' and coalesce((p_payment->>'amount')::numeric, 0) > 0 then
    v_pay := app.pay_goods_receipt(v_id, (p_payment->>'amount')::numeric, p_payment->>'method', p_payment->>'reference',
                                   null, coalesce((p_payment->>'from_till')::boolean, false), v_user);
  end if;

  return jsonb_build_object('id', v_id, 'number', v_no, 'total', v_total,
    'balance', v_total - coalesce((v_pay->>'amount')::numeric, 0),
    'purchase_order_status', v_po_status);
end $$;

create or replace function public.cancel_goods_receipt(p_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_user uuid := app.require_permission('stock.manage');
  g public.goods_receipts%rowtype; l record; v_po_status text; v_cost numeric; v_kept text[] := '{}';
begin
  perform app.require_feature('stock');
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Write a short reason for cancelling the receipt.'; end if;
  select * into g from public.goods_receipts
   where id = p_id and restaurant_id = app.current_restaurant_id() and branch_id = app.current_branch_id() for update;
  if not found then raise exception 'Goods receipt not found.'; end if;
  if g.status = 'cancelled' then raise exception 'Receipt % is already cancelled.', g.number; end if;
  if g.paid_total > 0 then
    raise exception 'Receipt % has a payment recorded against it, so it cannot be cancelled. Undo the payment first.', g.number;
  end if;
  -- Stock entries are never edited: the quantities go back out as their own entries.
  for l in select * from public.goods_receipt_lines where goods_receipt_id = g.id order by ingredient_id loop
    perform pg_advisory_xact_lock(hashtext('stock:' || g.branch_id::text || ':' || l.ingredient_id::text));
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, goods_receipt_id)
    values (g.restaurant_id, g.branch_id, l.ingredient_id, 'adjust', -l.qty, l.unit_cost, left(g.number || ' cancelled: ' || trim(p_reason), 200), v_user, g.id);
    -- The delivery also moved the ingredient's cost. If nothing else has changed
    -- the cost since, put back what it was; otherwise leave it and say so.
    select i.cost_per_unit into v_cost from public.ingredients i where i.id = l.ingredient_id;
    if l.prev_cost is not null and v_cost is not distinct from l.new_cost then
      update public.ingredients set cost_per_unit = l.prev_cost where id = l.ingredient_id and cost_per_unit is distinct from l.prev_cost;
    elsif v_cost is distinct from l.prev_cost then
      v_kept := v_kept || (select i.name from public.ingredients i where i.id = l.ingredient_id);
    end if;
    if g.purchase_order_id is not null then
      update public.purchase_order_lines set received_qty = greatest(0, received_qty - l.qty)
       where purchase_order_id = g.purchase_order_id and ingredient_id = l.ingredient_id;
    end if;
  end loop;
  update public.goods_receipts set status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
         cancel_reason = left(trim(p_reason), 300)
   where id = g.id;
  if g.purchase_order_id is not null then
    select case when not exists (select 1 from public.purchase_order_lines where purchase_order_id = g.purchase_order_id and received_qty > 0) then 'ordered'
                when exists (select 1 from public.purchase_order_lines where purchase_order_id = g.purchase_order_id and received_qty < qty) then 'part_received'
                else 'received' end into v_po_status;
    update public.purchase_orders set status = v_po_status, closed_at = case when v_po_status = 'received' then closed_at else null end
     where id = g.purchase_order_id and status <> 'cancelled';
  end if;
  perform app.audit('goods.cancel', 'goods_receipts', g.id, jsonb_build_object('number', g.number, 'reason', left(trim(p_reason), 300)),
                    jsonb_build_object('total', g.total));
  return jsonb_build_object('id', g.id, 'number', g.number, 'status', 'cancelled', 'cost_not_restored', to_jsonb(v_kept));
end $$;

------------------------------------------------------------------
-- What was bought and what is owed
------------------------------------------------------------------
create or replace function public.purchase_report(p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_rest uuid; v_branch uuid; v_today date; v_sup jsonb; v_owed jsonb; v_items jsonb; v_tot jsonb;
begin
  perform app.require_feature('stock');
  perform app.require_permission('stock.manage');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Choose a valid date range.'; end if;
  if p_to - p_from > 366 then raise exception 'Choose a range of one year or less.'; end if;
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  v_today := (now() at time zone (select timezone from public.restaurants where id = v_rest))::date;

  select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc), '[]'::jsonb) into v_sup from (
    select jsonb_build_object('supplier_id', s.id, 'supplier', s.name, 'receipts', count(*),
             'total', sum(g.total), 'paid', sum(g.paid_total), 'owed', sum(g.total - g.paid_total)) x
      from public.goods_receipts g join public.suppliers s on s.id = g.supplier_id
     where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received'
       and g.received_on between p_from and p_to
     group by s.id, s.name) z;

  -- Everything still owed, whenever it was received.
  select coalesce(jsonb_agg(x order by (x->>'due_on')), '[]'::jsonb) into v_owed from (
    select jsonb_build_object('id', g.id, 'number', g.number, 'supplier_id', s.id, 'supplier', s.name,
             'bill_no', g.supplier_bill_no, 'received_on', g.received_on, 'due_on', g.due_on,
             'total', g.total, 'paid', g.paid_total, 'owed', g.total - g.paid_total,
             'overdue', g.due_on is not null and g.due_on < v_today) x
      from public.goods_receipts g join public.suppliers s on s.id = g.supplier_id
     where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received' and g.total > g.paid_total) z;

  select coalesce(jsonb_agg(x order by (x->>'amount')::numeric desc), '[]'::jsonb) into v_items from (
    select jsonb_build_object('ingredient', i.name, 'unit', i.unit, 'category', i.category,
             'qty', sum(l.qty), 'amount', sum(l.line_total),
             'avg_cost', case when sum(l.qty) > 0 then round(sum(l.line_total) / sum(l.qty), 4) end) x
      from public.goods_receipt_lines l
      join public.goods_receipts g on g.id = l.goods_receipt_id
      join public.ingredients i on i.id = l.ingredient_id
     where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received'
       and g.received_on between p_from and p_to
     group by i.id, i.name, i.unit, i.category) z;

  select jsonb_build_object(
      'receipts', count(*) filter (where g.received_on between p_from and p_to),
      'bought', coalesce(sum(g.total) filter (where g.received_on between p_from and p_to), 0),
      'owed', coalesce(sum(g.total - g.paid_total), 0),
      'overdue', coalesce(sum(g.total - g.paid_total) filter (where g.due_on < v_today), 0))
    into v_tot
    from public.goods_receipts g
   where g.restaurant_id = v_rest and g.branch_id = v_branch and g.status = 'received';

  return jsonb_build_object('from', p_from, 'to', p_to, 'totals', v_tot, 'by_supplier', v_sup, 'owed', v_owed, 'by_ingredient', v_items);
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.save_supplier(uuid, jsonb)',
    'public.save_purchase_order(uuid, uuid, jsonb, date, text, boolean)',
    'public.set_purchase_order_status(uuid, text)',
    'public.pay_supplier(uuid, numeric, text, text, date, boolean, uuid)',
    'public.undo_supplier_payment(uuid, text)',
    'public.receive_goods(uuid, jsonb, uuid, text, date, numeric, numeric, date, text, jsonb, uuid)',
    'public.cancel_goods_receipt(uuid, text)',
    'public.purchase_report(date, date)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
