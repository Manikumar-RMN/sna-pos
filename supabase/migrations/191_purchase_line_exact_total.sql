-- 191: a purchase line typed in the buying unit keeps the EXACT amount billed.
-- 3 kg at 99.99 is 3000 g at 0.09999 per g, but a cost is stored to 4 decimals (0.1000), which would make the line 300.00 instead of
-- 299.97. app.purchase_lines now also returns line_total (typed quantity x typed price, 2 decimals) for lines typed in the buying unit,
-- and receive_goods uses it for the line total and the delivery total (so what you owe the supplier matches their bill).
-- Stock quantity and stock value are unchanged. Re-runnable.
do $$
declare d text; rg text;
begin
  d := pg_get_functiondef('app.purchase_lines(uuid, jsonb)'::regprocedure);
  if position('line_total' in d) = 0 then
    d := replace(d, 'RETURNS TABLE(ingredient_id uuid, qty numeric, unit_cost numeric)', 'RETURNS TABLE(ingredient_id uuid, qty numeric, unit_cost numeric, line_total numeric)');
    d := replace(d, E'    qty := round(coalesce((l->>''qty'')::numeric, 0), 3);\n', E'    line_total := null;\n    qty := round(coalesce((l->>''qty'')::numeric, 0), 3);\n');
    d := replace(d, E'      qty := round(qty * v_ing.purchase_factor, 3);\n', E'      if l ? ''unit_cost'' then line_total := round(qty * (l->>''unit_cost'')::numeric, 2); end if;\n      qty := round(qty * v_ing.purchase_factor, 3);\n');
    if position('line_total := round' in d) = 0 or position('line_total := null' in d) = 0 or position('line_total numeric)' in d) = 0 then
      raise exception 'purchase_lines text did not match; nothing changed';
    end if;
    drop function app.purchase_lines(uuid, jsonb);
    execute d;
    revoke all on function app.purchase_lines(uuid, jsonb) from public, anon, authenticated;
  end if;

  rg := pg_get_functiondef('public.receive_goods(uuid, jsonb, uuid, text, date, numeric, numeric, date, text, jsonb, uuid)'::regprocedure);
  if position('l.line_total' in rg) = 0 then
    rg := replace(rg, 'l.qty, l.unit_cost, round(l.qty * l.unit_cost, 2), v_prev_cost, v_new_cost', 'l.qty, l.unit_cost, coalesce(l.line_total, round(l.qty * l.unit_cost, 2)), v_prev_cost, v_new_cost');
    rg := replace(rg, 'v_sub := v_sub + round(l.qty * l.unit_cost, 2);', 'v_sub := v_sub + coalesce(l.line_total, round(l.qty * l.unit_cost, 2));');
    if position('l.line_total' in rg) = 0 then raise exception 'receive_goods text did not match; nothing changed'; end if;
    execute rg;
  end if;
end $$;
