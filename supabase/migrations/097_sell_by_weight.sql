-- 097: Sell by weight (bakery, sweets, desserts): price per kg, quantity such as 0.350 kg.
--
-- A dish can be sold by weight. Its price is per kg and a bill line's quantity is the weight in kg (up to 3 decimals).
-- The bill line remembers its unit ('kg') so receipts print "0.350 kg". products.barcode holds the item code that
-- a weighing scale prints in its barcode label (prefix 2 + 5-digit item code + 5-digit weight in grams + check digit).

alter table public.products
  add column sold_by text not null default 'unit' check (sold_by in ('unit', 'weight'));
alter table public.order_items
  add column unit text check (unit is null or unit = 'kg');

-- A weighed item's bill line is in kg; a piece item's line keeps whole numbers as before.
create or replace function app.trg_order_item_unit()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare v_by text;
begin
  select sold_by into v_by from public.products where id = new.product_id;
  if v_by = 'weight' then
    new.unit := 'kg';
    if new.quantity < 0.005 then raise exception 'Weigh % again: the weight is too small.', new.product_name; end if;
  else
    new.unit := null;
  end if;
  return new;
end $function$;
revoke all on function app.trg_order_item_unit() from public, anon, authenticated;
create trigger trg_order_item_unit before insert on public.order_items
  for each row execute function app.trg_order_item_unit();

-- The item code a scale prints must be unique among live dishes of one restaurant.
create unique index products_barcode_uq on public.products (restaurant_id, barcode)
  where barcode is not null and deleted_at is null;
