-- 261: Only liquor sales take stock.
-- "Liquor" is a dish whose tax group is marked "separate bill" (the same rule that puts liquor on its own bill).
-- Food dishes, even if they have a recipe, no longer take ingredients out of stock when sold.
-- Cancelling or voiding gives back only what was taken, so it follows automatically.

create or replace function app.is_liquor_product(p_product uuid)
returns boolean
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select coalesce((select tg.separate_bill from public.products p join public.tax_groups tg on tg.id = p.tax_group_id where p.id = p_product), false)
$$;

create or replace function app.item_recipe(p_item uuid, p_product uuid)
returns table(ingredient_id uuid, qty numeric)
language sql stable security definer set search_path to 'public', 'pg_temp'
as $$
  select x.ingredient_id, sum(x.qty)
    from (select rl.ingredient_id, rl.qty from public.recipe_lines rl
           where rl.product_id = p_product and app.is_liquor_product(rl.product_id)
          union all
          select rl.ingredient_id, rl.qty
            from public.order_item_modifiers om
            join public.modifier_items mi on mi.id = om.modifier_item_id
            join public.recipe_lines rl on rl.product_id = mi.product_id
           where om.order_item_id = p_item and app.is_liquor_product(mi.product_id)) x
   group by x.ingredient_id
$$;

create or replace function app.stock_on_item_option()
returns trigger
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare it public.order_items; v_pid uuid; v_branch uuid; v_qty numeric;
begin
  if new.modifier_item_id is null then return new; end if;
  select product_id into v_pid from public.modifier_items where id = new.modifier_item_id;
  if v_pid is null or not app.is_liquor_product(v_pid) or not exists (select 1 from public.recipe_lines where product_id = v_pid) then return new; end if;
  select * into it from public.order_items where id = new.order_item_id;
  if it.cancelled_at is not null then return new; end if;
  v_qty := it.quantity - coalesce(it.cancelled_qty, 0);
  if v_qty <= 0 then return new; end if;
  select branch_id into v_branch from public.orders where id = it.order_id;
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id)
  select it.restaurant_id, v_branch, rl.ingredient_id, 'sale', -(rl.qty * v_qty), it.order_id, it.id
    from public.recipe_lines rl where rl.product_id = v_pid;
  return new;
end $$;
