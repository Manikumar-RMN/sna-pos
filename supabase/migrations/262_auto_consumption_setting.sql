-- 262: Stock on sale works the Petpooja way.
-- One switch per outlet: "Take stock when a bill is made" (Yes/No). When Yes, an item takes stock only if it has a
-- recipe (liquor bottle pegs, ingredients and so on). Items without a recipe take nothing.
-- This replaces migration 261 (liquor-only rule): the liquor filter is removed.

drop function if exists app.is_liquor_product(uuid);

alter table public.branch_settings add column if not exists auto_consumption boolean not null default true;

create or replace function app.item_recipe(p_item uuid, p_product uuid)
returns table(ingredient_id uuid, qty numeric)
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select x.ingredient_id, sum(x.qty)
    from (select rl.ingredient_id, rl.qty from public.recipe_lines rl where rl.product_id = p_product
          union all
          select rl.ingredient_id, rl.qty
            from public.order_item_modifiers om
            join public.modifier_items mi on mi.id = om.modifier_item_id
            join public.recipe_lines rl on rl.product_id = mi.product_id
           where om.order_item_id = p_item) x
   group by x.ingredient_id
$$;

create or replace function app.stock_on_item()
returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_branch uuid; v_qty numeric;
begin
  select branch_id into v_branch from public.orders where id = new.order_id;
  if not coalesce((select auto_consumption from public.branch_settings where branch_id = v_branch), true) then return new; end if;
  if not exists (select 1 from app.item_recipe(new.id, new.product_id)) then return new; end if;
  if tg_op = 'INSERT' then
    v_qty := new.quantity;
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id)
    select new.restaurant_id, v_branch, r.ingredient_id, 'sale', -(r.qty * v_qty), new.order_id, new.id
      from app.item_recipe(new.id, new.product_id) r;
  elsif tg_op = 'UPDATE' then
    v_qty := coalesce(new.cancelled_qty, 0) - coalesce(old.cancelled_qty, 0);
    if v_qty = 0 and new.cancelled_at is not null and old.cancelled_at is null then v_qty := old.quantity; end if;
    if new.quantity < old.quantity and new.cancelled_at is null then v_qty := old.quantity - new.quantity; end if;
    if v_qty > 0 then
      insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id, note)
      select new.restaurant_id, v_branch, r.ingredient_id, 'returned', r.qty * v_qty, new.order_id, new.id, 'Item cancelled'
        from app.item_recipe(new.id, new.product_id) r;
    end if;
  end if;
  return new;
end $$;

create or replace function app.stock_on_item_option()
returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare it public.order_items; v_pid uuid; v_branch uuid; v_qty numeric;
begin
  if new.modifier_item_id is null then return new; end if;
  select product_id into v_pid from public.modifier_items where id = new.modifier_item_id;
  if v_pid is null or not exists (select 1 from public.recipe_lines where product_id = v_pid) then return new; end if;
  select * into it from public.order_items where id = new.order_item_id;
  if it.cancelled_at is not null then return new; end if;
  v_qty := it.quantity - coalesce(it.cancelled_qty, 0);
  if v_qty <= 0 then return new; end if;
  select branch_id into v_branch from public.orders where id = it.order_id;
  if not coalesce((select auto_consumption from public.branch_settings where branch_id = v_branch), true) then return new; end if;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id)
  select it.restaurant_id, v_branch, rl.ingredient_id, 'sale', -(rl.qty * v_qty), it.order_id, it.id
    from public.recipe_lines rl where rl.product_id = v_pid;
  return new;
end $$;

create or replace function public.save_stock_settings(p_auto_consumption boolean)
returns void
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  perform app.require_permission('settings.manage');
  update public.branch_settings set auto_consumption = p_auto_consumption, updated_at = now()
   where branch_id = app.current_branch_id();
  perform app.audit('settings.stock', 'branch_settings', null, jsonb_build_object('auto_consumption', p_auto_consumption), null);
end $$;
revoke all on function public.save_stock_settings(boolean) from public, anon;
grant execute on function public.save_stock_settings(boolean) to authenticated;
