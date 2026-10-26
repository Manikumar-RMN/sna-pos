# WS-B handover index (floor and item moves)

What WS-B built (all files new or owned by WS-B; nothing shared was edited):

| What | Where |
|---|---|
| Move item, database | supabase/migrations/132_move_order_items.sql (`public.move_order_items`) |
| Floor status, database | supabase/migrations/134_floor_status.sql (`public.floor_status`) |
| Colour rules (pure) + unit tests | app/src/lib/table-status.ts, app/src/lib/__tests__/table-status.test.ts |
| Table strip (WS-A composes it) | app/src/app/(app)/floor/{table-strip.tsx, load-floor.ts, use-floor-clock.ts} |
| Captain colours | app/src/app/(app)/captain/{page.tsx, captain.tsx} (edited, WS-B owned) |
| Move-item panel + its server action | app/src/app/(app)/bills/{move-item-panel.tsx, move-item-actions.ts} |
| Repeat last order | app/src/app/(app)/pos/repeat-round.ts (server action) + app/src/lib/repeat-round.ts (pure mapping) + tests |
| DB tests | docs/tests/t132-134.sql, docs/tests/run-t132-134.sh, docs/tests/t132-134-last-run.txt |

Snippets for files WS-B does not own:

1. `move-item-wiring.md`     -> WS-A: bills/bill-actions.tsx (and bill-screen.tsx if a prop is missing)
2. `table-strip-wiring.md`   -> WS-A: pos/page.tsx, pos/order-desk.tsx
3. `repeat-round-wiring.md`  -> WS-A: pos/pos-terminal.tsx
4. `database-types.md`       -> WS-F: lib/supabase/database.types.ts
5. `platform-notes.md`       -> WS-F: migration numbers, permissions (none new), erase_groups (none), go-live, QA

No new permission key, no new table, no nav link.
