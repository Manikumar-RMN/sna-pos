# WS-A1 -> WS-A2 (bill screen): receipt fields and the discount pool

`ReceiptData` (pos/receipt-view.tsx) gained two OPTIONAL fields; nothing breaks if you do not set them:
```ts
/** Loyalty points used as a discount before tax. Own line "Loyalty points discount". `discount` stays the manual part. */
loyaltyDiscount?: number;
/** earned / redeemed on THIS bill, balance after it. null/absent = no block. */
loyalty?: { earned: number; redeemed: number; balance: number } | null;   // type ReceiptLoyalty in lib/receipt-loyalty.ts
```
- Build them in bill-screen.tsx where `ReceiptData` is made: `loyaltyDiscount` = `orders.calc_params.loyalty_discount` (or the calc output key `loyalty_discount`); `discount` must then be the MANUAL part only (calc output `discount`), so the two lines add up to `orders.discount_total - senior`.
- `loyalty.earned` = ledger 'earn' rows for the bill, `redeemed` = points of the 'redeem' row (positive number), `balance` = `app.points_balance`. On an unpaid bill earned is 0.
- The block prints nothing when earned, redeemed and balance are all 0. The same lines print on the thermal (RawBT) receipt; both use `loyaltyLines()` in lib/receipt-loyalty.ts.
- `approval.tsx` already has the label for `loyalty.redeem` ("use loyalty points on this bill"): do not add it again.
- Discount dialog pool (your plan 3.4): the same words as the POS: "None of these items can be discounted." and "Discount applies to X of Y. Some items cannot be discounted." Offline helper `discountPool(snap, lines)` exists in lib/offline.ts but is not needed on the bill screen (online only). Use `calc.discountable_subtotal` from the database.
