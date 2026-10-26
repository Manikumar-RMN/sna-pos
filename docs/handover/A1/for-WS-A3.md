# WS-A1 -> WS-A3 (floor + kitchen): KOT slip prep line

- `lib/rawbt.ts` `KotTicket` got an optional `prepMin?: number | null`; `kotLines()` prints `~N min` after the ticket/bill line when set. `kitchen-board.tsx` builds its tickets for `kotLines(mine, ...)`: add `prepMin` there (max prep of the ticket's items, sizes inherit the dish) to print it on KDS-printed slips. Pure helper to copy or import: `app/src/app/(app)/pos/kot/[orderId]/prep.ts` (`maxPrep(productIds, byId)` with `PrepProduct = {id, parent_id, prep_minutes}`; test beside it).
- The KOT print after "Send KOT" (pos/kot) already prints `~N min` in the header line (screen and RawBT), read from `products.prep_minutes` (column from MIG/141).
- The Kitchen-waiting colour and the KDS card ("Prep N min") are yours (plan 3.3 / 3.4); nothing in the POS uses `kot_due_at`.
