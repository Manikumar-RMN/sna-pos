# Move item: wiring into BillActions (WS-A)

Target file: `app/src/app/(app)/bills/bill-actions.tsx`. WS-B already created `bills/move-item-panel.tsx` and `bills/move-item-actions.ts`
(the server action lives there, so `bills/actions.ts` needs NO change).

## 1. Import (next to the other imports at the top)

```tsx
import { MoveItemPanel } from "./move-item-panel";
```

## 2. Panel type (anchor: `type Panel = null | "split" | "move" | "merge" | "cancel" | "adjust" | "comp";`)

```tsx
type Panel = null | "split" | "move" | "moveItem" | "merge" | "cancel" | "adjust" | "comp";
```

## 3. Button (anchor: the `<PanelButton label="Move table" .../>` line in the "Table & items" grid; put it right after it)

```tsx
<PanelButton label="Move item" active={panel === "moveItem"} onClick={() => setPanel(panel === "moveItem" ? null : "moveItem")} />
```

## 4. Panel body (anchor: just before `{panel === "merge" && (`)

```tsx
{panel === "moveItem" && (
  <div className="mt-3 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
    <MoveItemPanel
      orderId={orderId}
      billNumber={billNumber}
      lines={lines}
      tables={tables}
      currentTableId={tableId}
      blocked={
        hasPayments
          ? "This bill already has a payment, so items cannot be moved off it. Split the payment instead."
          : hasDiscount
            ? "This bill has a discount, so items cannot be moved. Remove the discount first or split the payment."
            : null
      }
      onMoved={() => {
        setPanel(null);
        router.refresh();
      }}
    />
  </div>
)}
```

`lines` (`{id,name,options,qty}[]`), `tables` (`{id,number,busy}[]`), `tableId`, `hasPayments`, `hasDiscount`, `billNumber` are
all existing BillActions props, so no change to `bill-screen.tsx`. The panel's `MoveLine` / `MoveTable` types match them structurally.

## Notes

- The panel runs inside `BillActions`' own `ApprovalPrompt`-free area; it carries its own manager-PIN prompt (the database says
  `(order.create)` if the right is missing), so nothing is needed in `run()`.
- Complimentary bills: the database refuses ("has a discount or is complimentary"); the panel shows that message. No prop needed.
- After a move `router.refresh()` is enough in classic mode. In the one-screen layout call the same `router.refresh()`; if the moved
  bill should also be opened, `onMoved` receives `{ toOrderId, toBillNumber, toTable, newBill }`.
- Offline: this needs internet (like every action on an open bill). The server action simply fails with the usual message offline; if
  WS-A disables open-bill actions offline, disable this button too.
- Visible only where "Table & items" is visible (`showPay`), i.e. the bill is open.
