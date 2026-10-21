-- 126: adding a dish at a price needs the "Change prices" right (F-5)
--
-- Before this change a person with only "Edit menu" (menu.manage) could ADD a dish
-- (or a size, or upload new dishes) at any price, while CHANGING a price already
-- needed "Change prices" (menu.price_change, guard_product_change in 032/033).
-- Now an insert with a price above zero needs the same right. A price of 0 is still
-- allowed, so a menu-only person can add a dish and let someone with the right set the price.
--
-- Additive only: a new function and a new BEFORE INSERT trigger on public.products.
-- app.guard_product_change() is NOT replaced. Same convention as 033: when no person is
-- signed in (app.current_user_id() is null: restaurant set-up, erase/seed, other trusted
-- server work) nothing is checked. The tax group on insert stays open to menu.manage
-- (the default Manager role has no tax.manage); the insert is still audit-logged
-- (menu.item_added) by guard_product_change.
-- Sizes are stored as products rows with parent_id set, so this trigger covers them too.

create or replace function app.guard_product_insert_price() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if app.current_user_id() is null then return new; end if;
  if new.price is not null and new.price > 0 and not app.has_permission('menu.price_change') then
    raise exception 'You do not have the right to set prices.';
  end if;
  return new;
end $$;
revoke all on function app.guard_product_insert_price() from public, anon, authenticated;

drop trigger if exists trg_guard_product_insert_price on public.products;
create trigger trg_guard_product_insert_price before insert on public.products
  for each row execute function app.guard_product_insert_price();

-- Roll back:
--   drop trigger if exists trg_guard_product_insert_price on public.products;
--   drop function if exists app.guard_product_insert_price();
