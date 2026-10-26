# What the database now does for the till and receipt (WS-DB -> WS-A1)

Migrations 141, 147. Golden numbers: `golden-bill.md` and `calc-bill-golden-141.json` in this folder (the plan's 232.40 is really **212.40**).

## Menu snapshot (offline copy)
- `products.discount_restricted boolean` ("Do not allow discounts on this item") and `products.prep_minutes smallint` (1..240 or null) are new columns.
  A size (product row with `parent_id`) carries its own copy; the database copies the dish's value to its sizes when the dish changes, and when it reads a bill it takes the size's flag first, else the dish's.
  Put `discount_restricted` (dish or size, as stored) in the offline menu snapshot, and send `no_disc: true` on that line in `calc-bill.ts` exactly as the golden cases do.
- A till with an old menu copy is corrected on sync: `sync_offline_bill` recalculates with the server's flags and writes the flag `discount_cut` (`asked`, `recorded`) when the typed discount was cut to the discountable part.

## What changes in the answers (all additive, only when a restricted line or points are involved)
- `quote_order` / `app.calc_bill` output: `discountable_subtotal` only when at least one line is restricted; `loyalty_discount` only when points were asked for. `discount` stays the typed part.
  `orders.discount_total` = typed + points. Lines without restricted dishes and without points are byte-identical to before (the existing golden JSON passes unchanged).
- `create_order` with a typed discount above the discountable part but not above the whole bill: the discount is **cut** to the discountable part (no error). Above the whole bill: the old refusal.
- `adjust_order`: "The discount can be at most 100.00 (some items on this bill cannot be discounted)." (two decimals) when the typed amount is above the pool; with points on the bill:
  "The discount can be at most N (loyalty points already pay M of this bill)."
- `order_items.discount_blocked boolean` is the snapshot on the line (split / move / merge keep it). It is read-only for the app.
- `order_discounts.discount_type` may now be `'loyalty_points'` (value = points, amount = money). The receipt / bill view should print it as "Loyalty points" (amount) like the other discount rows.
- A complimentary / staff-meal bill ignores the flag (the whole bill comes off).
- Senior/PWD, happy-hour/offer prices, gift cards and points-as-payment are not discounts and ignore the flag.

## Offline bills with a guest (147)
`sync_offline_bill(p_bill)` accepts optional `guest_phone` and `guest_name` keys. The phone finds or starts the customer exactly like `create_order`; the bill is stored with `customer_id`,
`guest_name`, `guest_phone` and the loyalty points are earned when the sync marks it paid (once: a retried sync returns the first answer). A phone with fewer than 7 digits is dropped and the bill gets the flag
`guest_phone_invalid` (summary text: "guest phone number was too short and was not saved"). Points can only be **redeemed** online.
