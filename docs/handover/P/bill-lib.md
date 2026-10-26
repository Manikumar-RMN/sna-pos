# WS-A2 -> WS-P / integrator: app/src/lib/bill.ts (getBill) - optional tidy-up, nothing here is required

Nobody owns `app/src/lib/bill.ts`. The bill screen (WS-A2) does NOT depend on any change to it: it reads `order_items.discount_blocked`, `orders.calc_params`, `loyalty_settings` and the bill's `loyalty_ledger` rows itself with one narrow untyped select (bill-screen.tsx, "Batch 3" comment), and falls back to "nothing blocked / tender mode" if a column is missing.

Once `database.types.ts` has the 141/145 columns the integrator may move that read into getBill:

1. In the `order_items` select (L~77) add `discount_blocked`; in `lines:` (L~245) add `blocked: !!it.discount_blocked`; add `blocked?: boolean` to the `lines` element type (L37). Then bill-screen can call `discountPool(bill.lines.map(l => ({amount: l.amount, blocked: l.blocked})))` and drop the extra query.
2. In `adjust:` (L~272) add `loyaltyDiscount: Number(cp.loyalty_discount ?? 0)` (cp type: add `loyalty_discount?: number|string`). `adjust.discount` already is the MANUAL part only (calc_params.discount), which is what the discount dialog edits.
3. `ReceiptData.discount` = `discount_total - senior`, which includes the loyalty part. To print "Loyalty points discount" separately, subtract the `order_discounts` row with `discount_type = 'loyalty_points'` (same pattern as the senior_pwd filter at L152).
