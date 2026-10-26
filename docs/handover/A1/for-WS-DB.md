# WS-A1 -> WS-DB: what the POS terminal now expects from the database

Everything below is optional on the wire (old SQL + new app degrades), except the typed `rpc("stock_warnings")` and the typed selects, which need database.types.ts (plan section 6 "new app + old SQL does not work").

## 1. database.types.ts (A1 code uses these; add when generating)
- `products` Row/Insert/Update: `discount_restricted: boolean` (insert/update optional), `prep_minutes: number | null`.
- `order_items` Row: `discount_blocked: boolean`.
- Functions: `stock_warnings: { Args: { p_items: Json }; Returns: Json }`.
- Used by: `pos/menu-data.ts` (select `discount_restricted` on products), `pos/kot/[orderId]/actions.ts` (select `prep_minutes, parent_id` on products), `pos/actions.ts` (`rpc("stock_warnings", { p_items })`).

## 2. offline_snapshot (MIG/122 body, replaced in 141 or 147)
In the per-product `jsonb_build_object` of the menu array add (the flag is on the size row too; the variant-follow trigger keeps it equal to the dish):
```sql
'no_discount', coalesce(p.discount_restricted, false),
```
and in the `settings` object add:
```sql
'loyalty', app.has_module('loyalty')   -- whatever helper the function already uses for module checks
```
Why: the till mirrors the discount block offline (`SnapItem.no_discount`, `Snapshot.settings.loyalty` in lib/offline.ts) and the offline receipt says "Points will be added after sync" only when `settings.loyalty` is true. Both are optional on the client: an old snapshot reads as "discountable" / "no loyalty", and the server corrects such a bill on sync (flag `discount_cut`).

## 3. sync_offline_bill (MIG/147)
The queued offline bill (lib/offline.ts `OfflineBill`) now carries, besides the existing `guest: {name, phone, address} | null`:
- `guest_name` (text, only when typed), `guest_phone` (text as typed, only when typed). Takeaway/delivery bills only (dine-in has no guest box). The phone has >= 7 digits already checked on the till.
Please read `p_bill->>'guest_phone'` / `'guest_name'` (fall back to `p_bill->'guest'->>'phone'/'name'` for bills queued by an older till).
The terminal's second step (`syncOfflineBill` in pos/actions.ts: `set_order_guest` after the bill is saved) is left in place: it only runs when the bill has no guest details yet (a repeat sync keeps what is there) and it still carries the delivery address. It is harmless when 147 already attached the customer. If you want to retire it, say so and A1 removes it.
The `discount_cut` flag has `asked` and `recorded` keys (as in MIG/140); lib/offline-flags.ts words them: "The till took X off, but the bill allows Y".

## 4. stock_warnings (MIG/143)
The POS strip works with the specified answer `{warnings:[{ingredient_id,name,unit,need,on_hand,after,level}]}`. One optional extra makes a dot appear on the cart line of the dish that uses the short ingredient: add to each warning `product_ids` (uuid array, the cart items' product ids that need this ingredient). Without it the strip still works.
Called with `p_items = [{product_id, qty, options:[modifier_item_ids]}]`; the packing charge and open-price lines are never sent as special cases (no recipe -> no warning).

## 5. quote_order / create_order / calc_bill output (MIG/141)
The terminal reads these optional keys from `quote_order`: `discount` (manual part, after the cap), `loyalty_discount`, `discountable_subtotal`. lib/calc-bill.ts returns the same keys; names must match exactly.

## 6. Golden numbers (docs/handover/A1/golden-bill.md from you)
lib/calc-bill.ts is parameterised for them: save the DB oracle results as `app/src/lib/__tests__/calc-bill.<anything>.golden.json` in the SAME shape as calc-bill.golden.json (`{cases:[{case, input, expected}]}`). `expected` may carry `grand_total, tax_total, service_charge, discount, loyalty_discount, discountable_subtotal, senior_discount, rounding` and optionally `lines:[{key, discount, tax, total}]`. `calc-bill.test.ts` runs every `calc-bill.*.golden.json` in the folder automatically, so nothing else changes. `calc-bill.block.golden.json` (A1's provisional cases, `oracle` = hand | mirror) can be deleted once yours covers the same ground.
Line input keys: `no_disc` (boolean, only when true). Bill input keys: `discount` (manual), `loyalty_discount`.
