# Table strip + colours: wiring into the order screen (WS-A)

Files: `pos/page.tsx` (server) and `pos/order-desk.tsx` (new, WS-A). WS-B built `floor/table-strip.tsx` (client), `floor/load-floor.ts`
(server helper), `floor/use-floor-clock.ts`, and `lib/table-status.ts`.

## 1. pos/page.tsx: load the floor facts in parallel with the rest

```tsx
import { loadFloor } from "../floor/load-floor";
// inside the Promise.all([...]) that loads menu, tables, openTabs ... add:  loadFloor()
// e.g.  const [..., floor] = await Promise.all([..., loadFloor()]);
```

`loadFloor()` never throws: if migration 134 is not applied or the call fails it returns `[]`, and the strip falls back to plain
free / busy from `tables[].openBills`. So deploy order does not matter.

## 2. The strip needs each open bill's total

`openByTable` currently stores `{ id, billNumber }`. Add the total (the `openTabs` query must select `grand_total`):

```tsx
list.push({ id: o.id, billNumber: o.bill_number, total: Number(o.grand_total ?? 0) });
```

## 3. Use it in order-desk.tsx

```tsx
import { TableStrip } from "../floor/table-strip";
import type { FloorRow } from "@/lib/table-status";

// props from page.tsx:  tables: { id: string; number: string; seats?: number | null; busy: boolean; openBills: { id: string; billNumber: string; total: number }[] }[];  floor: FloorRow[]
<TableStrip
  tables={tables.map((t) => ({ id: t.id, number: t.number, seats: t.seats ?? null, openBills: t.openBills }))}
  floor={floor}
  currency={currency}
  selectedTableId={selectedTableId}
  selectedBillId={selectedBillId}
  onSelect={(tableId, billId) => {
    // billId set: that open bill is selected -> router.push(`/pos?bill=${billId}`)
    // billId null: no bill yet (or the choice among several bills / "+ New bill") -> router.push(`/pos?table=${tableId}`)
  }}
  counter={{ selected: counterSelected, onSelect: () => router.push("/pos") }}   // optional "Counter / takeaway" tile
  refreshMs={20000}                                                             // 0 if order-desk refreshes itself
/>
```

Behaviour you can rely on:
- A table with exactly one open bill calls `onSelect(tableId, thatBillId)`; with several, `onSelect(tableId, null)` and, once the
  table is the selected one, the strip shows chips for its bills plus "+ New bill" (each calls `onSelect`).
- Colours: free / busy / open too long (>90 min) / kitchen waiting (>15 min) / reserved (booking 60 min before to 30 min after).
  A free table whose booking is near shows "Reserved". Selecting a reserved table is allowed (guests arriving). The legend is
  printed under the strip (text + colour).
- `refreshMs` calls `router.refresh()` on an interval; the strip's clock uses the database clock (no dependence on the tablet's).
- Hide the strip for `compact` layouts with `compact` (smaller tiles).

## 4. Nothing else

No change to PosTerminal is needed for colours. The existing `tables[].busy` / `openBills` props keep working.
