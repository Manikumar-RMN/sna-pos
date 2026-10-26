# WS-A2 -> WS-A1: receipt loyalty block, and the approval label

## 1. `ReceiptData.loyalty` (target: app/src/app/(app)/pos/receipt-view.tsx, type `ReceiptData`)

WS-A1 defines the optional field; WS-A2 supplies it. Exact shape WS-A2 passes:

```ts
/** Loyalty points for this bill (only when the outlet has the loyalty module and a guest is on the bill). */
loyalty?: { earned: number; redeemed: number; balance: number };
```

- `earned`  = points earned by THIS bill (ledger `earn` rows minus `reverse` rows for the order; 0 until the bill is paid).
- `redeemed` = points used by THIS bill (ledger `redeem` rows plus any `adjust` rows of this order, so "Remove points" and "Bill changed" give-backs net out). Never negative.
- `balance` = the guest's points balance now.
- Absent when no guest is on the bill or the loyalty module is off. The receipt prints nothing in that case, so old receipts are unchanged.

Supplied in `app/src/app/(app)/bills/bill-screen.tsx`: `const receipt: ReceiptData & { loyalty?: ... } = guest ? { ...r, loyalty: receiptLoyalty(rows, guest.points) } : r;` and `<ReceiptView data={receipt} .../>`. The helper is `receiptLoyalty` in `bills/loyalty-math.ts` (tested). Once the field exists on `ReceiptData` the intersection type is redundant but harmless.

Suggested receipt lines (WS-A1 decides the layout): "Points earned: N", "Points used: N", "Points balance: N" (only the ones that are > 0, balance always).

The discount line on the receipt: points used as a discount are part of `ReceiptData.discount` (orders.discount_total includes the loyalty part). If you want the separate label "Loyalty points discount", getBill (app/src/lib/bill.ts) would have to split it; see docs/handover/P/bill-lib.md.

## 2. Approval label (target: app/src/app/(app)/approval.tsx, const `LABELS`)

Add after `"order.discount": ...`:

```ts
  "loyalty.redeem": "use loyalty points on this bill",
```

The server error from `redeem_points_discount` carries "(loyalty.redeem)", `neededRight` finds it and `LoyaltyPanel` opens `ApprovalPrompt` with that permission, then retries with the same client_ref.
