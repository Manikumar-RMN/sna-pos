# TypeScript types for migrations 143 / 144 (for database.types.ts, owned by the other DB agent)

Target: app/src/lib/supabase/database.types.ts. Anchors: add the tables in `Tables`, columns on `stock_movements`, functions in `Functions` (alphabetical).

## stock_movements (existing table): new columns
Row: `business_date: string` (NOT NULL), `reason: string | null`, `count_id: string | null`, `client_ref: string | null`
Insert/Update: `business_date?: string`, `reason?: string | null`, `count_id?: string | null`, `client_ref?: string | null`
reason values: spoilage | expired | spill | breakage | staff_meal | sample | theft | count_correction | other

## New tables (select-only for signed-in users; Relationships may be left empty)
stock_counts Row: { id: string; restaurant_id: string; branch_id: string; business_date: string; note: string | null; created_by: string | null; created_at: string; client_ref: string | null }
stock_count_lines Row: { count_id: string; restaurant_id: string; branch_id: string; ingredient_id: string; expected: number; counted: number; diff: number; unit_cost: number; value_diff: number }

## Functions (Args -> Returns)
```ts
adjust_stock: { Args: { p_ingredient: string; p_kind: string /* wastage|adjust_in|adjust_out */; p_qty: number; p_reason: string; p_note?: string | null; p_client_ref?: string | null }; Returns: Json }
// {movement_id, kind, change (signed), value, stock (new level at this outlet), repeat?: true}
low_stock_items: { Args: { p_limit?: number }; Returns: Json }
// {items:[{ingredient_id, name, unit, on_hand, reorder_level, status:'negative'|'out'|'low'}], counts:{out, low, negative}}
record_stock: { Args: { p_ingredient_id: string; p_kind: string; p_qty: number; p_unit_cost?: number | null; p_note?: string | null }; Returns: Json }  // unchanged signature; {stock, change}
report_food_cost: { Args: { p_from: string; p_to: string }; Returns: Json }
report_stock_movement: { Args: { p_from: string; p_to: string }; Returns: Json }
report_stock_on_hand: { Args: { p_as_of?: string | null }; Returns: Json }
report_wastage: { Args: { p_from: string; p_to: string }; Returns: Json }
stock_count_apply: { Args: { p_lines: Json /* [{ingredient_id, counted}] */; p_note?: string | null; p_client_ref?: string | null }; Returns: Json }
// {count_id, lines, adjusted, variance_value, repeat?: true}
stock_in_quick: { Args: { p_lines: Json /* [{ingredient_id, qty, unit_cost}] */; p_supplier_note?: string | null; p_bill_ref?: string | null; p_client_ref?: string | null }; Returns: Json }
// {lines:[{ingredient_id,name,unit,qty,unit_cost,new_cost,stock}], count, total_value, repeat?: true}
stock_warnings: { Args: { p_items: Json /* [{product_id, qty, options:[modifier_item_id]}] */ }; Returns: Json }
// {warnings:[{ingredient_id, name, unit, need, on_hand, after, level:'out'|'low'}]}   (empty list when module off)
```

## Return shapes of the four reports (exact keys)
- report_stock_on_hand: {as_of, all_outlets, rows:[{branch_id, outlet_name, ingredient_id, name, category, unit, on_hand, cost, value, reorder_level, status:'ok'|'low'|'out'|'negative'}], by_outlet:[{branch_id, outlet_name, value, items, low, out, negative}], totals:{value, items, low, out, negative}}
- report_stock_movement: {all_outlets, rows:[{branch_id, outlet_name, ingredient_id, name, unit, opening, purchased, transfer_in, transfer_out, used, wasted, adjusted, counted, closing}], details:[{id, business_date, at, kind, qty, unit_cost|null, value|null, reason, note, bill_number, user_name, branch_id, outlet_name, ingredient_id, name, unit}], truncated, row_limit, total_rows, by_outlet:[{branch_id, outlet_name, purchased_value, used_value, wasted_value, adjusted_value, counted_value}], totals:{rows, movements, purchased_value, used_value, wasted_value, adjusted_value, counted_value}}
- report_food_cost: {all_outlets, by_day:[{business_date, net_sales_all, net_sales_covered, cost|null, cost_pct|null}], by_dish:[{product_id, name, qty_sold, net_sales, cost|null, cost_pct|null, margin|null, has_recipe}], by_outlet:[{branch_id, outlet_name, net_sales_all, net_sales_covered, cost|null, cost_pct|null}], totals:{net_sales_all, net_sales_covered, coverage_pct|null, cost, cost_pct|null, wastage_cost}}
- report_wastage: {all_outlets, by_reason:[{reason, lines, value}], by_ingredient:[{ingredient_id, name, unit, qty, value}], by_day:[{business_date, lines, value}], by_user:[{user_id, user_name, lines, value}], by_outlet:[{branch_id, outlet_name, lines, value}], rows:[{id, business_date, at, branch_id, outlet_name, ingredient_id, name, unit, qty, unit_cost, value, reason, note, user_name}], truncated, row_limit, total_rows, totals:{lines, value}}
Numbers are JSON numbers. Used/wasted/transfer_out are positive (consumption); adjusted/counted are signed.
