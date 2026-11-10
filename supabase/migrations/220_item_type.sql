-- Item type: every stock item is Food (goes into dishes and prepared items) or General (pens, notebooks, cleaning
-- supplies: bought, issued, counted, but never part of a recipe). Existing items stay Food.

alter table public.ingredients add column if not exists item_type text not null default 'food';
alter table public.ingredients drop constraint if exists ingredients_item_type_check;
alter table public.ingredients add constraint ingredients_item_type_check check (item_type in ('food', 'general'));
grant select (item_type) on public.ingredients to authenticated, sna_pos_agent;

-- A General item may not be used in a dish recipe or a production recipe.
create or replace function app.block_general_in_recipe() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_name text;
begin
  if tg_table_name = 'production_boms' then
    v_id := new.output_ingredient_id;
  else
    v_id := new.ingredient_id;
  end if;
  select name into v_name from public.ingredients where id = v_id and item_type = 'general';
  if v_name is not null then
    raise exception '% is a General item, so it cannot be used in a recipe. Change its type to Food first.', v_name;
  end if;
  return new;
end $$;

drop trigger if exists recipe_lines_no_general on public.recipe_lines;
create trigger recipe_lines_no_general before insert or update of ingredient_id on public.recipe_lines
  for each row execute function app.block_general_in_recipe();
drop trigger if exists production_bom_lines_no_general on public.production_bom_lines;
create trigger production_bom_lines_no_general before insert or update of ingredient_id on public.production_bom_lines
  for each row execute function app.block_general_in_recipe();
drop trigger if exists production_boms_no_general on public.production_boms;
create trigger production_boms_no_general before insert or update of output_ingredient_id on public.production_boms
  for each row execute function app.block_general_in_recipe();

-- save_ingredient: one more optional argument. Left out, an edit keeps the type and a new item is Food.
drop function if exists public.save_ingredient(uuid, text, text, numeric, numeric, text, text, numeric);
create or replace function public.save_ingredient(p_id uuid, p_name text, p_unit text, p_cost numeric, p_reorder numeric, p_category text default null::text,
                                                  p_purchase_unit text default null::text, p_purchase_factor numeric default 1, p_item_type text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid;
        v_pu text := nullif(left(trim(coalesce(p_purchase_unit, '')), 20), ''); v_pf numeric := coalesce(p_purchase_factor, 1);
        v_type text := nullif(trim(coalesce(p_item_type, '')), '');
begin
  perform app.require_feature('stock');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the item name.'; end if;
  if v_type is not null and v_type not in ('food', 'general') then raise exception 'Choose Food or General.'; end if;
  if v_pf <= 0 or v_pf > 1000000 then raise exception 'The buying unit must hold more than 0 of the stock unit.'; end if;
  if v_pu is null then v_pf := 1; end if;
  if exists (select 1 from public.ingredients where restaurant_id = v_rest and is_active and lower(trim(name)) = lower(trim(p_name)) and id is distinct from p_id) then
    raise exception 'An item called % already exists.', trim(p_name);
  end if;
  if p_id is null then
    insert into public.ingredients (restaurant_id, name, unit, cost_per_unit, reorder_level, category, purchase_unit, purchase_factor, item_type)
    values (v_rest, left(trim(p_name), 60), p_unit, coalesce(p_cost, 0), coalesce(p_reorder, 0), nullif(left(trim(coalesce(p_category, '')), 40), ''), v_pu, v_pf, coalesce(v_type, 'food')) returning id into v_id;
  else
    if v_type = 'general' and (exists (select 1 from public.recipe_lines where ingredient_id = p_id)
                               or exists (select 1 from public.production_bom_lines where ingredient_id = p_id)
                               or exists (select 1 from public.production_boms where output_ingredient_id = p_id)) then
      raise exception 'This item is used in a recipe. Take it out of the recipes before making it a General item.';
    end if;
    update public.ingredients set name = left(trim(p_name), 60), unit = p_unit, cost_per_unit = coalesce(p_cost, 0), reorder_level = coalesce(p_reorder, 0),
           category = nullif(left(trim(coalesce(p_category, '')), 40), ''), purchase_unit = v_pu, purchase_factor = v_pf, item_type = coalesce(v_type, item_type)
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'Item not found.'; end if;
  end if;
  perform app.audit('stock.ingredient', 'ingredients', v_id, jsonb_build_object('name', p_name, 'unit', p_unit, 'cost', p_cost, 'reorder', p_reorder, 'purchase_unit', v_pu, 'purchase_factor', v_pf, 'item_type', coalesce(v_type, 'food')));
  return v_id;
end $function$;
revoke all on function public.save_ingredient(uuid, text, text, numeric, numeric, text, text, numeric, text) from public, anon;
grant execute on function public.save_ingredient(uuid, text, text, numeric, numeric, text, text, numeric, text) to authenticated, service_role;
