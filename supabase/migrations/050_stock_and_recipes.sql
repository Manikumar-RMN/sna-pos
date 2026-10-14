-- Recovered from the live database's own migration history (supabase_migrations.schema_migrations):
-- version 20260928093811, name '50_stock_and_recipes'. This is the SQL that actually ran.

insert into public.permissions (key, description, is_sensitive) values ('stock.manage', 'Manage stock, purchases and recipes', true)
on conflict (key) do nothing;
insert into public.role_permissions (role_id, permission_key)
select r.id, 'stock.manage' from public.roles r where r.is_system and r.name in ('Owner', 'Manager') on conflict do nothing;

create table public.ingredients (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 60),
  unit text not null check (unit in ('kg', 'g', 'l', 'ml', 'pcs', 'pack')),
  cost_per_unit numeric(12,4) not null default 0 check (cost_per_unit >= 0),
  reorder_level numeric(12,3) not null default 0 check (reorder_level >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (restaurant_id, id)
);
create unique index ingredients_name_uq on public.ingredients (restaurant_id, lower(trim(name))) where is_active;

create table public.recipe_lines (
  restaurant_id uuid not null,
  product_id uuid not null,
  ingredient_id uuid not null,
  qty numeric(12,4) not null check (qty > 0),
  primary key (product_id, ingredient_id),
  foreign key (restaurant_id, product_id) references public.products(restaurant_id, id) on delete cascade,
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id) on delete cascade
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null,
  branch_id uuid not null,
  ingredient_id uuid not null,
  kind text not null check (kind in ('purchase', 'sale', 'returned', 'wastage', 'count', 'adjust')),
  qty numeric(14,4) not null,
  unit_cost numeric(12,4),
  order_id uuid,
  order_item_id uuid,
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  foreign key (restaurant_id, ingredient_id) references public.ingredients(restaurant_id, id),
  foreign key (restaurant_id, branch_id) references public.branches(restaurant_id, id)
);
create index stock_movements_lookup on public.stock_movements (branch_id, ingredient_id, created_at);
create trigger trg_no_update_stock before update on public.stock_movements for each row execute function app.block_update();
create trigger trg_no_delete_stock before delete on public.stock_movements for each row execute function app.block_delete();

alter table public.ingredients enable row level security;
alter table public.recipe_lines enable row level security;
alter table public.stock_movements enable row level security;
create policy tenant_read on public.ingredients for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
create policy tenant_read on public.recipe_lines for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
create policy tenant_read on public.stock_movements for select to authenticated using (restaurant_id = (select app.current_restaurant_id()));
grant select on public.ingredients, public.recipe_lines, public.stock_movements to authenticated;

-- Sales use up ingredients as items go on a bill; cancelled items and voided bills put them back.
create or replace function app.stock_on_item() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_branch uuid; v_qty numeric;
begin
  if not exists (select 1 from public.recipe_lines where product_id = new.product_id) then return new; end if;
  select branch_id into v_branch from public.orders where id = new.order_id;
  if tg_op = 'INSERT' then
    v_qty := new.quantity;
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id)
    select new.restaurant_id, v_branch, rl.ingredient_id, 'sale', -(rl.qty * v_qty), new.order_id, new.id
      from public.recipe_lines rl where rl.product_id = new.product_id;
  elsif tg_op = 'UPDATE' then
    -- Item cancelled (fully or partly): return what was cancelled this time.
    v_qty := coalesce(new.cancelled_qty, 0) - coalesce(old.cancelled_qty, 0);
    if v_qty = 0 and new.cancelled_at is not null and old.cancelled_at is null then v_qty := old.quantity; end if;
    if new.quantity < old.quantity and new.cancelled_at is null then v_qty := old.quantity - new.quantity; end if;
    if v_qty > 0 then
      insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id, note)
      select new.restaurant_id, v_branch, rl.ingredient_id, 'returned', rl.qty * v_qty, new.order_id, new.id, 'Item cancelled'
        from public.recipe_lines rl where rl.product_id = new.product_id;
    end if;
  end if;
  return new;
end $$;
create trigger trg_stock_on_item after insert or update of quantity, cancelled_qty, cancelled_at on public.order_items
  for each row execute function app.stock_on_item();

create or replace function app.stock_on_void() returns trigger
language plpgsql security definer set search_path to 'public','pg_temp' as $$
begin
  if new.status = 'voided' and old.status <> 'voided' then
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, note)
    select new.restaurant_id, new.branch_id, sm.ingredient_id, 'returned', -sum(sm.qty), new.id, 'Bill voided'
      from public.stock_movements sm where sm.order_id = new.id and sm.kind in ('sale', 'returned')
     group by sm.ingredient_id having sum(sm.qty) < 0;
  end if;
  return new;
end $$;
create trigger trg_stock_on_void after update of status on public.orders for each row execute function app.stock_on_void();

create or replace function public.save_ingredient(p_id uuid, p_name text, p_unit text, p_cost numeric, p_reorder numeric) returns uuid
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid;
begin
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the ingredient name.'; end if;
  if exists (select 1 from public.ingredients where restaurant_id = v_rest and is_active and lower(trim(name)) = lower(trim(p_name)) and id is distinct from p_id) then
    raise exception 'An ingredient called % already exists.', trim(p_name);
  end if;
  if p_id is null then
    insert into public.ingredients (restaurant_id, name, unit, cost_per_unit, reorder_level)
    values (v_rest, left(trim(p_name), 60), p_unit, coalesce(p_cost, 0), coalesce(p_reorder, 0)) returning id into v_id;
  else
    update public.ingredients set name = left(trim(p_name), 60), unit = p_unit, cost_per_unit = coalesce(p_cost, 0), reorder_level = coalesce(p_reorder, 0)
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'Ingredient not found.'; end if;
  end if;
  perform app.audit('stock.ingredient', 'ingredients', v_id, jsonb_build_object('name', p_name, 'unit', p_unit, 'cost', p_cost, 'reorder', p_reorder));
  return v_id;
end $$;

create or replace function public.save_recipe(p_product_id uuid, p_lines jsonb) returns int
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); n int;
begin
  if not exists (select 1 from public.products where id = p_product_id and restaurant_id = v_rest) then raise exception 'Item not found.'; end if;
  delete from public.recipe_lines where product_id = p_product_id;
  insert into public.recipe_lines (restaurant_id, product_id, ingredient_id, qty)
  select v_rest, p_product_id, (l->>'ingredient_id')::uuid, (l->>'qty')::numeric
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) l
   where coalesce((l->>'qty')::numeric, 0) > 0
     and exists (select 1 from public.ingredients i where i.id = (l->>'ingredient_id')::uuid and i.restaurant_id = v_rest);
  get diagnostics n = row_count;
  perform app.audit('stock.recipe', 'products', p_product_id, jsonb_build_object('lines', p_lines));
  return n;
end $$;

-- Purchase, wastage or a physical count ("we have 4.5 kg") for this branch.
create or replace function public.record_stock(p_ingredient_id uuid, p_kind text, p_qty numeric, p_unit_cost numeric default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare
  v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_branch uuid := app.current_branch_id();
  v_ing public.ingredients%rowtype; v_now numeric; v_move numeric;
begin
  select * into v_ing from public.ingredients where id = p_ingredient_id and restaurant_id = v_rest;
  if not found then raise exception 'Ingredient not found.'; end if;
  if p_kind not in ('purchase', 'wastage', 'count') then raise exception 'Choose purchase, wastage or count.'; end if;
  if p_qty is null or p_qty < 0 or (p_kind <> 'count' and p_qty = 0) then raise exception 'Enter a quantity.'; end if;
  select coalesce(sum(qty), 0) into v_now from public.stock_movements where branch_id = v_branch and ingredient_id = v_ing.id;
  v_move := case p_kind when 'purchase' then p_qty when 'wastage' then -p_qty else p_qty - v_now end;
  if v_move = 0 and p_kind = 'count' then return jsonb_build_object('stock', v_now, 'change', 0); end if;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by)
  values (v_rest, v_branch, v_ing.id, p_kind, v_move, case when p_kind = 'purchase' then p_unit_cost end, nullif(left(trim(coalesce(p_note, '')), 200), ''), v_user);
  -- A purchase at a new price updates the ingredient's cost (weighted with the stock already held).
  if p_kind = 'purchase' and p_unit_cost is not null and p_unit_cost >= 0 then
    update public.ingredients set cost_per_unit = case when v_now > 0 then round((v_now * cost_per_unit + p_qty * p_unit_cost) / (v_now + p_qty), 4) else p_unit_cost end
     where id = v_ing.id;
  end if;
  perform app.audit('stock.' || p_kind, 'ingredients', v_ing.id, jsonb_build_object('qty', p_qty, 'change', v_move, 'unit_cost', p_unit_cost, 'note', p_note));
  return jsonb_build_object('stock', v_now + v_move, 'change', v_move);
end $$;

-- Stock levels, usage and food cost for a date range.
create or replace function public.stock_report(p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_rest uuid; v_branch uuid; v_tz text; v_start timestamptz; v_end timestamptz; v_levels jsonb; v_costs jsonb;
begin
  perform app.require_permission('stock.manage');
  v_rest := app.current_restaurant_id(); v_branch := app.current_branch_id();
  select timezone into v_tz from public.restaurants where id = v_rest;
  v_start := p_from::timestamp at time zone v_tz; v_end := (p_to + 1)::timestamp at time zone v_tz;
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb) into v_levels from (
    select jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost', i.cost_per_unit, 'reorder', i.reorder_level,
      'stock', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id), 0),
      'used', -coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind in ('sale', 'returned') and m.created_at >= v_start and m.created_at < v_end), 0),
      'wasted', -coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind = 'wastage' and m.created_at >= v_start and m.created_at < v_end), 0),
      'bought', coalesce((select sum(qty) from public.stock_movements m where m.branch_id = v_branch and m.ingredient_id = i.id
                          and m.kind = 'purchase' and m.created_at >= v_start and m.created_at < v_end), 0),
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
end $$;

revoke all on function public.save_ingredient(uuid,text,text,numeric,numeric), public.save_recipe(uuid,jsonb),
  public.record_stock(uuid,text,numeric,numeric,text), public.stock_report(date,date) from public, anon;
grant execute on function public.save_ingredient(uuid,text,text,numeric,numeric), public.save_recipe(uuid,jsonb),
  public.record_stock(uuid,text,numeric,numeric,text), public.stock_report(date,date) to authenticated;
