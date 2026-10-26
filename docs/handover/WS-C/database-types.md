# WS-C -> WS-F: lib/supabase/database.types.ts additions
Target: `app/src/lib/supabase/database.types.ts` (hand-edit, same layout as the neighbours).

1. `Tables.products` Row/Insert/Update: `is_open_price: boolean` (Row), `is_open_price?: boolean` (Insert, Update).
2. `Tables.order_items` Row/Insert/Update: `open_price: boolean` (Row), `open_price?: boolean` (Insert, Update).
3. New table `order_tips` (anchor: alphabetically after `order_items`; copy the shape of another select-only table such as `online_orders`):
   Row = { id: string; restaurant_id: string; branch_id: string | null; order_id: string; payment_id: string | null; method_id: string | null;
           amount: number; waiter_id: string | null; received_by: string | null; shift_id: string | null; business_date: string | null; created_at: string };
   Insert/Update: all optional except restaurant_id, order_id, amount (the app never writes it; only pay_order does). Relationships: [] is fine.
4. `Functions` (anchor: next to `save_tax_group` / `pay_order`):
```ts
schedule_tax_group: { Args: { p_group: string; p_components: Json; p_effective_from: string }; Returns: Json }
cancel_scheduled_tax: { Args: { p_group: string }; Returns: Json }
```
5. `Functions.pay_order.Args`: add `p_tip?: number` (the function now has 7 arguments; the 6-argument version no longer exists).
Without 1, 3-5 the code in settings/actions.ts (scheduleTaxGroup, cancelScheduledTax), menu/actions.ts (is_open_price) and bills/actions.ts (p_tip) will not type-check.
