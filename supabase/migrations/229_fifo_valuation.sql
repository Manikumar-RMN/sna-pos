-- FIFO stock valuation, shown beside the weighted-average value the system uses.
-- Read only: how stock is costed does not change. FIFO value takes what is on hand from the newest
-- receipts backwards (net of goods sent back) at the rate each was bought; any part not covered by a
-- receipt (opening stock, count gains) is valued at the current average cost.
create or replace function public.report_fifo_valuation() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rest uuid; v_rb uuid;
begin
  perform app.require_stock_any(array['stock.view', 'stock.manage']);
  perform app.require_feature('stock');
  v_rest := app.current_restaurant_id(); v_rb := app.report_branch();
  return (
    with oh as (
      select m.branch_id, m.ingredient_id, sum(m.qty) as on_hand
        from public.stock_movements m
       where m.restaurant_id = v_rest and (v_rb is null or m.branch_id = v_rb)
       group by m.branch_id, m.ingredient_id having sum(m.qty) > 0.0005),
    lots as (
      select g.branch_id, l.ingredient_id, l.unit_cost,
             greatest(0, least(l.qty - l.returned_qty, oh.on_hand - coalesce(sum(l.qty - l.returned_qty) over (
               partition by g.branch_id, l.ingredient_id order by g.received_on desc, g.created_at desc, l.id desc
               rows between unbounded preceding and 1 preceding), 0))) as q
        from public.goods_receipt_lines l
        join public.goods_receipts g on g.id = l.goods_receipt_id
        join oh on oh.branch_id = g.branch_id and oh.ingredient_id = l.ingredient_id
       where g.restaurant_id = v_rest and g.status = 'received'),
    f as (select branch_id, ingredient_id, sum(q) as covered, sum(q * unit_cost) as val from lots group by branch_id, ingredient_id),
    x as (
      select b.name as outlet, i.name as item, i.unit, coalesce(i.category, '') as category, oh.on_hand, i.cost_per_unit as avg_cost,
             round(oh.on_hand * i.cost_per_unit, 2) as avg_value,
             round(coalesce(f.val, 0) + greatest(0, oh.on_hand - coalesce(f.covered, 0)) * i.cost_per_unit, 2) as fifo_value,
             greatest(0, oh.on_hand - coalesce(f.covered, 0)) as uncovered
        from oh join public.ingredients i on i.id = oh.ingredient_id
        join public.branches b on b.id = oh.branch_id
        left join f on f.branch_id = oh.branch_id and f.ingredient_id = oh.ingredient_id
       where i.restaurant_id = v_rest)
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object('outlet', outlet, 'item', item, 'unit', unit, 'category', category,
                'on_hand', round(on_hand, 3), 'avg_cost', round(avg_cost, 4), 'avg_value', avg_value, 'fifo_value', fifo_value,
                'diff', round(fifo_value - avg_value, 2), 'uncovered', round(uncovered, 3)) order by outlet, item) from x), '[]'::jsonb),
      'totals', jsonb_build_object('avg_value', coalesce((select round(sum(avg_value), 2) from x), 0),
                'fifo_value', coalesce((select round(sum(fifo_value), 2) from x), 0),
                'diff', coalesce((select round(sum(fifo_value - avg_value), 2) from x), 0)))
  );
end $$;
revoke all on function public.report_fifo_valuation() from public, anon;
grant execute on function public.report_fifo_valuation() to authenticated;
