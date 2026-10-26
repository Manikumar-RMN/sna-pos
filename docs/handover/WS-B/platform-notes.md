# Platform notes (WS-F)

- **Migrations**: WS-B uses 132 (`132_move_order_items.sql`) and 134 (`134_floor_status.sql`). Both are one `create or replace function` +
  revoke/grant, additive and re-runnable (the test script runs each twice). 132 needs only things that exist at 129 (request_refs from 077,
  app.recalc_order, app.next_bill_number / next_liquor_number, app.auto_shift, app.audit, kitchen_tickets with the 125 columns). It does NOT
  depend on 130, 131 or 133. 134 needs `reservations` (064) and `dining_tables.is_kiosk`.
- **Permissions**: none new. Move item and the floor view use the existing `order.create` (every role that takes orders has it).
  Nothing to add to `lib/permissions.ts` or to migration 139.
- **erase_groups**: no new table, nothing to register (`request_refs`, where kind `move_items` rows go, is an existing table).
- **Audit**: new action `order.move_item` (entity `orders` = the target bill; new_value has from_bill, from_table, to_bill, to_table, new_bill, items[], from_total, to_total).
  For the Audit report label (`lib/reports-pack.ts` AUDIT_ACTION_LABEL, WS-E): `"order.move_item": "Item moved to another table"`.
  Not an owner alert (not in app.audit_to_alert's list), by design: it changes no money.
- **Go-live**: if a go-live file is built (`docs/tests/build-go-live-NNN.sh`), append 132 and 134 verbatim (each is a single function).
  Prerequisite check: 129 recorded. Re-run `docs/tests/run-t132-134.sh` against the final migration set after 130/131/133/135-139 land.
- **Floor RPC cost**: one query per table via lateral joins on indexed columns (orders by dining_table_id, kitchen_tickets by order_id,
  reservations by table). Fine for hundreds of tables; the screen calls it every 20 s per open screen.
- **QA additions** (from plan section 5): table colours match thresholds on /pos and Captain; reservation turns a free table "Reserved";
  move item: totals, kitchen "ready" alert shows the new table, second tap does not move twice; repeat last order sends a new ticket.
