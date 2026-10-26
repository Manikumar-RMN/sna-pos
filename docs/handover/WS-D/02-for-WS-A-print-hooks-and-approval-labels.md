# WS-D -> WS-A: reprint hooks and approval labels

Server action (done, WS-D): `app/src/app/(app)/bills/log-print.ts`

```ts
logPrint({ kind: "bill" | "kot", orderId: string, ticketIds?: string[] })
  -> { ok: true; reprint: boolean; action: string; printNo?: number } | { ok: false; error: string }
```
Rules enforced in the database (migration 135):
- bill: the first print of a bill is silent (`bill.print`), any later print is a reprint: needs `order.reprint` or a manager PIN, logged `bill.reprint`.
- kot: call it ONLY for a reprint (the normal first print is claim_tickets_for_print). It always needs `order.reprint` or a PIN, logged `kot.reprint` with the ticket numbers.
- When `ok` is false and the text contains `(order.reprint)`, show `ApprovalPrompt` (permission `order.reprint`), then call `logPrint` again. Print ONLY when `ok` is true. After a PIN approval the approval is consumed by that one call.

## 1. approval.tsx LABELS (add)
```ts
  "order.reprint": "reprint this bill or kitchen ticket",
  "menu.price_change": "change prices",
```
(`menu.price_change` is used by the bulk price screen, which already imports `ApprovalPrompt`, `neededRight`, `cleanMessage` from `approval.tsx`.)

## 2. receipt-view.tsx - printBill()
Wrap the existing print so the log happens first:
```ts
import { logPrint } from "../bills/log-print";
import { ApprovalPrompt, neededRight } from "../approval";

const [needsPin, setNeedsPin] = useState(false);
const [printError, setPrintError] = useState<string | null>(null);

async function printBillLogged() {
  setPrintError(null);
  const res = await logPrint({ kind: "bill", orderId: receipt.orderId });
  if (!res.ok) {
    if (neededRight(res.error) === "order.reprint") { setNeedsPin(true); return; }
    setPrintError(res.error);
    return;
  }
  printBill(); // the existing function (window.print / RawBT)
}
// ...
{needsPin && <ApprovalPrompt permission="order.reprint" onCancel={() => setNeedsPin(false)} onApproved={() => { setNeedsPin(false); void printBillLogged(); }} />}
```
The `?print=1` auto-print right after payment is the FIRST print: call `printBillLogged()` there too (first print is silent, so no prompt). Reopening the receipt later and pressing Print is then a reprint.
Limits (state in the QA notes): Ctrl+P / browser menu print and offline receipts are not logged.

## 3. kot-printer.tsx - printAgain()
```ts
async function printAgain() {
  const res = await logPrint({ kind: "kot", orderId, ticketIds: tickets.map((t) => t.id) });
  if (!res.ok) { if (neededRight(res.error) === "order.reprint") { setNeedsPin(true); return; } setError(res.error); return; }
  doPrint(); // existing
}
```
The automatic first print right after "Send KOT" must NOT call logPrint.

## 4. captain/kot-sheet.tsx - "Reprint" button
Same pattern with `ticketIds: [ticket.id]` (or all tickets of the round). Show the PIN prompt on `(order.reprint)`.
Stewards have no `order.reprint` by default, so on the captain phone they see the PIN prompt and a manager types a PIN.

## 5. Reports (WS-E)
Audit actions written: `bill.print`, `bill.reprint`, `kot.reprint` (entity_type `orders`, entity_id = order id). `new_value`: `{bill_number, print_no}`; kot: `{bill_number, tickets: ["K-1"], ticket_ids: [...]}`; reprint also has `old_value {prints_before}`.
