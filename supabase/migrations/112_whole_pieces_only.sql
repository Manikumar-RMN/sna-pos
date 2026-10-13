-- 112: A dish sold by the piece takes whole quantities only (QA round 1, critical).
--
-- Before: 0.001 of a Rs 120 meal made a Rs 0.00 bill. Now only dishes sold by weight (kg) may have decimals.
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
    if new.quantity <> trunc(new.quantity) then
      raise exception '% is sold by the piece: enter a whole number.', new.product_name;
    end if;
  end if;
  return new;
end $function$;

-- The same rule when a line's quantity is changed later.
drop trigger if exists trg_order_item_unit_upd on public.order_items;
create trigger trg_order_item_unit_upd before update of quantity on public.order_items
  for each row when (new.quantity is distinct from old.quantity)
  execute function app.trg_order_item_unit();
