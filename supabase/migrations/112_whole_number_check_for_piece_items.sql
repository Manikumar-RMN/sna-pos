-- 112: Captured from the live database; ALREADY APPLIED THERE (it was changed directly, outside the migration history).
--
-- Items sold by the piece must be a whole number, and that is checked when a bill line is added AND when its
-- quantity is changed later. Migration 097 created the function and the INSERT trigger without the whole-number
-- rule and without the UPDATE trigger; the live database has both. Written so that running it again changes nothing.

CREATE OR REPLACE FUNCTION app.trg_order_item_unit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

DROP TRIGGER IF EXISTS trg_order_item_unit_upd ON public.order_items;
CREATE TRIGGER trg_order_item_unit_upd BEFORE UPDATE OF quantity ON public.order_items
  FOR EACH ROW WHEN (new.quantity IS DISTINCT FROM old.quantity) EXECUTE FUNCTION app.trg_order_item_unit();
