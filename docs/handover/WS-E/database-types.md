# database.types.ts: three new functions (owner: WS-F)

File: `app/src/lib/supabase/database.types.ts`, inside `Functions`, alphabetical order. Same style as `report_pending_kot`.

Insert after `report_bills_detail` (before `report_discounts`):

```ts
      report_covers: { Args: { p_from: string; p_to: string }; Returns: Json }
```

Insert after `report_popular_items` (before `report_sales_day_book`):

```ts
      report_reprints: { Args: { p_from: string; p_to: string }; Returns: Json }
```

Insert `report_tips` after `report_tax` and before `report_unsold_items`:

```ts
      report_tips: { Args: { p_from: string; p_to: string }; Returns: Json }
```

`report_pending_kot` and `report_pending_bills` keep their signatures (only the function bodies changed in 138): no edit.
The pages read the Json through the safe parsers in `lib/reports-pack-3.ts`, so no row types are needed.

## Migration 139 notes (WS-F)
- Migration 138 creates no table and no permission key. Nothing to grant or register in `app.erase_groups()` for 138.
- 138 reads `public.order_tips` (migration 133) and `public.audit_logs` rows with action `bill.reprint` / `kot.reprint` (migration 135).
  Functions are plpgsql, so 138 can be applied before 133, but `report_tips` fails ("relation order_tips does not exist") until 133 is in.
  Keep the order 133, 135, 138.
- The reprint report expects the audit row to have entity_type `orders` (or `order`) and entity_id = the order id, so the bill number and table can be shown.
  Other fields it reads from `new_value`, all optional: `reprint_no` (or `count`), `ticket_ids` (array) or `tickets`, `reason`, `approver`, `bill_number` (used when entity_id is not an order).
  Please tell WS-D if log_print uses other names; only `reprintDetailText` in `lib/reports-pack-3.ts` needs to change.
