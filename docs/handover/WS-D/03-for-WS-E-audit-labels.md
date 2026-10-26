# WS-D -> WS-E: audit action labels (lib/reports-pack.ts AUDIT_ACTION_LABEL)

New audit actions written by migrations 135-137 (entity_type / key fields in brackets):
- `bill.print`           "Bill printed" [orders; new_value {bill_number, print_no}]
- `bill.reprint`         "Bill reprinted" [orders; new_value {bill_number, print_no}, old_value {prints_before}]
- `kot.reprint`          "Kitchen ticket reprinted" [orders; new_value {bill_number, tickets[], ticket_ids[]}]
- `menu.bulk_price_change` "Prices changed in bulk" [price_change_batches; new_value {batch_id, mode, value, rounding, reason, prices_changed, base_prices, outlet_prices, scope}]
- `menu.bulk_price_undo`  "Bulk price change undone" [price_change_batches; new_value {batch_id, restored, skipped, reason}, old_value {reason}]
- `role.rights_copied`   "Rights copied between profiles" [role; new_value {name, from_role, mode, added[], removed[], rights}]
- `user.access_copied`   "Access copied from another person" [users; new_value {role, from_user, outlets[], all_outlets}, old_value {role}]

`report_reprints` should list `bill.reprint` and `kot.reprint` (first prints, `bill.print`, are not reprints).
Owner alerts: `menu.bulk_price_change` and `menu.bulk_price_undo` are inserted into owner_alerts directly by the functions (one each per batch).
