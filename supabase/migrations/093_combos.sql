-- 093: Combos and meal deals (Burger + Fries + Drink at one price, choose your drink).
--
-- A combo is a dish with its own price whose options are other dishes: an option can point at a dish
-- (modifier_items.product_id). Choosing it takes that dish's ingredients out of stock, and the kitchen
-- ticket lists the chosen dishes under the combo. products.is_combo only marks the dish as a combo.

alter table public.products add column is_combo boolean not null default false;

alter table public.modifier_items
  add column product_id uuid,
  add constraint modifier_items_product_same_rest foreign key (restaurant_id, product_id)
      references public.products (restaurant_id, id) on delete restrict;
create index idx_modifier_items_product on public.modifier_items (product_id) where product_id is not null;

-- A choice cannot be a combo itself, or a dish that is sold only through its sizes.
create or replace function app.trg_modifier_item_dish()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare p public.products;
begin
  if new.product_id is null then return new; end if;
  select * into p from public.products where id = new.product_id;
  if p.is_combo then raise exception 'A combo cannot be a choice inside another combo.'; end if;
  if p.is_charge then raise exception 'The packing charge cannot be a choice.'; end if;
  if exists (select 1 from public.products s where s.parent_id = p.id and s.deleted_at is null) then
    raise exception '% is sold in sizes. Choose one of its sizes instead.', p.name;
  end if;
  return new;
end $function$;
revoke all on function app.trg_modifier_item_dish() from public, anon, authenticated;
create trigger trg_modifier_item_dish before insert or update of product_id on public.modifier_items
  for each row execute function app.trg_modifier_item_dish();

-- A dish that is a choice in a combo cannot itself become a combo.
create or replace function app.trg_product_combo_flag()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.is_combo and not coalesce(old.is_combo, false)
     and exists (select 1 from public.modifier_items mi where mi.product_id = new.id and mi.is_active) then
    raise exception '% is a choice inside a combo, so it cannot be a combo itself.', new.name;
  end if;
  if new.is_combo and new.parent_id is not null then
    raise exception 'A size cannot be a combo. Make the combo a dish of its own.';
  end if;
  return new;
end $function$;
revoke all on function app.trg_product_combo_flag() from public, anon, authenticated;
create trigger trg_product_combo_flag before insert or update of is_combo, parent_id on public.products
  for each row execute function app.trg_product_combo_flag();

-- The ingredients of one unit of a bill line: the dish's recipe plus the recipes of the dishes chosen in it.
create or replace function app.item_recipe(p_item uuid, p_product uuid)
returns table (ingredient_id uuid, qty numeric)
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
  select x.ingredient_id, sum(x.qty)
    from (select rl.ingredient_id, rl.qty from public.recipe_lines rl where rl.product_id = p_product
          union all
          select rl.ingredient_id, rl.qty
            from public.order_item_modifiers om
            join public.modifier_items mi on mi.id = om.modifier_item_id
            join public.recipe_lines rl on rl.product_id = mi.product_id
           where om.order_item_id = p_item) x
   group by x.ingredient_id
$function$;
revoke all on function app.item_recipe(uuid, uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION app.stock_on_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_branch uuid; v_qty numeric;
begin
  -- Recipe of the dish and of any dishes chosen in it (combos). When a line is first saved its choices are not
  -- saved yet; trg_stock_on_item_option takes those out as each choice is saved.
  if not exists (select 1 from app.item_recipe(new.id, new.product_id)) then return new; end if;
  select branch_id into v_branch from public.orders where id = new.order_id;
  if tg_op = 'INSERT' then
    v_qty := new.quantity;
    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id)
    select new.restaurant_id, v_branch, r.ingredient_id, 'sale', -(r.qty * v_qty), new.order_id, new.id
      from app.item_recipe(new.id, new.product_id) r;
  elsif tg_op = 'UPDATE' then
    -- Item cancelled (fully or partly): return what was cancelled this time.
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
end $function$;

-- A dish chosen inside a combo: take its ingredients out of stock for the line's quantity.
create or replace function app.stock_on_item_option()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
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
  insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, order_id, order_item_id)
  select it.restaurant_id, v_branch, rl.ingredient_id, 'sale', -(rl.qty * v_qty), it.order_id, it.id
    from public.recipe_lines rl where rl.product_id = v_pid;
  return new;
end $function$;
revoke all on function app.stock_on_item_option() from public, anon, authenticated;
create trigger trg_stock_on_item_option after insert on public.order_item_modifiers
  for each row execute function app.stock_on_item_option();

-- The billing screen marks combos.
create or replace view public.v_menu with (security_invoker = true) as
 SELECT p.id,
    p.restaurant_id,
    p.category_id,
    p.tax_group_id,
    p.name,
    p.short_name,
    COALESCE(bp.price, p.price)::numeric(14,2) AS price,
    p.is_veg,
    p.is_available AND COALESCE(bp.is_available, true) AS is_available,
    p.display_order,
    c.name AS category_name,
    c.display_order AS category_order,
    tg.name AS tax_group_name,
    tg.is_price_inclusive,
    ( SELECT tr.total_rate
           FROM tax_rates tr
          WHERE tr.tax_group_id = p.tax_group_id AND tr.valid_from <= CURRENT_DATE AND (tr.valid_to IS NULL OR tr.valid_to >= CURRENT_DATE)
          ORDER BY tr.valid_from DESC
         LIMIT 1) AS tax_rate,
    p.price AS menu_price,
    p.name_local,
    p.parent_id,
    p.variant_name,
    p.is_combo
   FROM products p
     JOIN categories c ON c.id = p.category_id
     JOIN tax_groups tg ON tg.id = p.tax_group_id
     LEFT JOIN branch_prices bp ON bp.product_id = p.id AND bp.branch_id = (( SELECT app.current_branch_id() AS current_branch_id))
  WHERE p.deleted_at IS NULL AND c.deleted_at IS NULL;
