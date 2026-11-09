-- 190: Round 2 of the stock audit.
--   1. Purchase unit. An ingredient has one stock unit (what recipes use, e.g. g). It can now also have a "buy in" unit and a factor
--      (1 kg = 1000 g). A purchase line may say "unit": "purchase"; the database then turns the quantity and the price into the stock unit
--      (2 kg at 95 per kg = 2000 g at 0.095 per g). Nothing changes for lines that do not say it.
--   2. One costing rule. receive_goods now uses the same function as the Stock screen (app.apply_purchase_cost): the new price is
--      weighted with ALL the stock the restaurant holds, because an ingredient has one cost per restaurant. Before, receive_goods
--      weighted against this outlet's stock only, so two outlets gave different costs for the same purchase.
-- Re-runnable.

alter table public.ingredients add column if not exists purchase_unit text;
alter table public.ingredients add column if not exists purchase_factor numeric(14,4) not null default 1;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ingredients_purchase_factor_check') then
    alter table public.ingredients add constraint ingredients_purchase_factor_check check (purchase_factor > 0 and purchase_factor <= 1000000);
  end if;
end $$;

-- save_ingredient: two new optional arguments (the old call still works).
drop function if exists public.save_ingredient(uuid, text, text, numeric, numeric, text);
create or replace function public.save_ingredient(p_id uuid, p_name text, p_unit text, p_cost numeric, p_reorder numeric, p_category text default null::text,
                                                  p_purchase_unit text default null::text, p_purchase_factor numeric default 1)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_user uuid := app.require_permission('stock.manage'); v_rest uuid := app.current_restaurant_id(); v_id uuid;
        v_pu text := nullif(left(trim(coalesce(p_purchase_unit, '')), 20), ''); v_pf numeric := coalesce(p_purchase_factor, 1);
begin
  perform app.require_feature('stock');
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter the ingredient name.'; end if;
  if v_pf <= 0 or v_pf > 1000000 then raise exception 'The buying unit must hold more than 0 of the stock unit.'; end if;
  if v_pu is null then v_pf := 1; end if;
  if exists (select 1 from public.ingredients where restaurant_id = v_rest and is_active and lower(trim(name)) = lower(trim(p_name)) and id is distinct from p_id) then
    raise exception 'An ingredient called % already exists.', trim(p_name);
  end if;
  if p_id is null then
    insert into public.ingredients (restaurant_id, name, unit, cost_per_unit, reorder_level, category, purchase_unit, purchase_factor)
    values (v_rest, left(trim(p_name), 60), p_unit, coalesce(p_cost, 0), coalesce(p_reorder, 0), nullif(left(trim(coalesce(p_category, '')), 40), ''), v_pu, v_pf) returning id into v_id;
  else
    update public.ingredients set name = left(trim(p_name), 60), unit = p_unit, cost_per_unit = coalesce(p_cost, 0), reorder_level = coalesce(p_reorder, 0),
           category = nullif(left(trim(coalesce(p_category, '')), 40), ''), purchase_unit = v_pu, purchase_factor = v_pf
     where id = p_id and restaurant_id = v_rest returning id into v_id;
    if v_id is null then raise exception 'Ingredient not found.'; end if;
  end if;
  perform app.audit('stock.ingredient', 'ingredients', v_id, jsonb_build_object('name', p_name, 'unit', p_unit, 'cost', p_cost, 'reorder', p_reorder, 'purchase_unit', v_pu, 'purchase_factor', v_pf));
  return v_id;
end $function$;
revoke all on function public.save_ingredient(uuid, text, text, numeric, numeric, text, text, numeric) from public, anon;
grant execute on function public.save_ingredient(uuid, text, text, numeric, numeric, text, text, numeric) to authenticated, service_role;

-- Purchase lines (purchase orders and goods received): honour "unit": "purchase".
do $$
declare d text;
begin
  d := pg_get_functiondef('app.purchase_lines(uuid, jsonb)'::regprocedure);
  if position('purchase_factor' in d) > 0 then return; end if;
  d := replace(d, E'    qty := round(coalesce((l->>''qty'')::numeric, 0), 3);\n    unit_cost := round(coalesce((l->>''unit_cost'')::numeric, v_ing.cost_per_unit, 0), 4);',
  E'    qty := round(coalesce((l->>''qty'')::numeric, 0), 3);\n    unit_cost := round(coalesce((l->>''unit_cost'')::numeric, v_ing.cost_per_unit, 0), 4);\n    -- "unit": "purchase" = typed in the buying unit (kg): turn it into the stock unit (g).\n    if l->>''unit'' = ''purchase'' and v_ing.purchase_factor is distinct from 1 and v_ing.purchase_factor > 0 then\n      qty := round(qty * v_ing.purchase_factor, 3);\n      if l ? ''unit_cost'' then unit_cost := round((l->>''unit_cost'')::numeric / v_ing.purchase_factor, 4); end if;\n    end if;');
  if position('purchase_factor' in d) = 0 then raise exception 'purchase_lines text did not match; nothing changed'; end if;
  execute d;
end $$;

-- Quick stock-in: same conversion.
do $$
declare d text; f text := E'(case when x.e->>''unit'' = ''purchase'' then (select greatest(i.purchase_factor, 0.0001) from public.ingredients i where i.id = (x.e->>''ingredient_id'')::uuid) else 1 end)';
begin
  d := pg_get_functiondef('public.stock_in_quick(jsonb, text, text, uuid)'::regprocedure);
  if position('x.e->>''unit''' in d) > 0 then return; end if;
  d := replace(d, E'app.stock_num(x.e->>''qty'') as qty, app.stock_num(x.e->>''unit_cost'') as cost, x.ord',
                  E'app.stock_num(x.e->>''qty'') * ' || f || E' as qty, app.stock_num(x.e->>''unit_cost'') / ' || f || E' as cost, x.ord');
  if position('x.e->>''unit''' in d) = 0 then raise exception 'stock_in_quick text did not match; nothing changed'; end if;
  execute d;
end $$;

-- receive_goods: one costing rule (same function as the Stock screen), called BEFORE the movement is written.
do $$
declare d text; a text; b text;
begin
  d := pg_get_functiondef('public.receive_goods(uuid, jsonb, uuid, text, date, numeric, numeric, date, text, jsonb, uuid)'::regprocedure);
  if position('apply_purchase_cost' in d) > 0 then return; end if;
  a := E'    -- Same rule as a purchase on the Stock screen: the new price is weighted with the stock already held.\n    select i.cost_per_unit into v_prev_cost from public.ingredients i where i.id = l.ingredient_id;\n    update public.ingredients i set cost_per_unit = case when v_now > 0\n             then round((v_now * i.cost_per_unit + l.qty * l.unit_cost) / (v_now + l.qty), 4) else l.unit_cost end\n     where i.id = l.ingredient_id\n    returning i.cost_per_unit into v_new_cost;\n';
  b := E'    insert into public.stock_movements (restaurant_id, branch_id, ingredient_id, kind, qty, unit_cost, note, created_by, goods_receipt_id)';
  if position(a in d) = 0 or position(b in d) = 0 then raise exception 'receive_goods text did not match; nothing changed'; end if;
  d := replace(d, a, '');
  d := replace(d, b, E'    -- One costing rule: the same function as the Stock screen (weighted with all the stock the restaurant holds).\n    select i.cost_per_unit into v_prev_cost from public.ingredients i where i.id = l.ingredient_id;\n    v_new_cost := app.apply_purchase_cost(l.ingredient_id, l.qty, l.unit_cost);\n' || b);
  execute d;
end $$;
