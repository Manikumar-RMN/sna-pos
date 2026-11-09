-- Returns now credit the tax that was on the returned goods, so the supplier balance matches the supplier's credit note.
-- The last return on a line takes exactly the tax still left, so tax never drifts by rounding.
alter table public.goods_return_lines add column if not exists tax_amount numeric(14,2) not null default 0;
alter table public.goods_receipts add column if not exists returned_tax numeric(14,2) not null default 0;

do $$
declare d text; o text;
begin
  d := pg_get_functiondef('public.return_goods(uuid,jsonb,text,uuid)'::regprocedure);
  if position('v_txsum' in d) > 0 then return; end if;
  o := d;
  d := replace(d, 'v_qty numeric; v_paid text;', 'v_qty numeric; v_paid text; v_tx numeric(14,2); v_txsum numeric(14,2) := 0; v_clsum numeric(14,2) := 0;');
  d := replace(d, E'    insert into public.goods_return_lines (restaurant_id, goods_return_id, ingredient_id, qty, unit_cost, line_total)\n    values (v_rest, v_id, x.ingredient_id, v_qty, gl.unit_cost, v_val);',
$r$    v_tx := case when coalesce(gl.tax_amount, 0) = 0 then 0
                 when v_qty = gl.qty - gl.returned_qty
                 then greatest(0, gl.tax_amount - coalesce((select sum(rl.tax_amount) from public.goods_return_lines rl
                        join public.goods_returns rr on rr.id = rl.goods_return_id
                       where rr.goods_receipt_id = g.id and rl.ingredient_id = x.ingredient_id), 0))
                 else round(gl.tax_amount * v_qty / gl.qty, 2) end;
    insert into public.goods_return_lines (restaurant_id, goods_return_id, ingredient_id, qty, unit_cost, line_total, tax_amount)
    values (v_rest, v_id, x.ingredient_id, v_qty, gl.unit_cost, v_val, v_tx);$r$);
  d := replace(d, 'v_total := v_total + v_val;', 'v_total := v_total + v_val + v_tx; v_txsum := v_txsum + v_tx; if gl.tax_claimable then v_clsum := v_clsum + v_tx; end if;');
  d := replace(d, 'returned_total = returned_total + v_total, payment_status', 'returned_total = returned_total + v_total, returned_tax = returned_tax + v_txsum, input_tax_claimable = greatest(0, input_tax_claimable - v_clsum), payment_status');
  if d = o or position('v_clsum := v_clsum' in d) = 0 or position('returned_tax = returned_tax' in d) = 0 or position('v_tx := case' in d) = 0 or position('v_tx numeric' in d) = 0 then
    raise exception 'return_goods anchors not found';
  end if;
  execute d;
end $$;
