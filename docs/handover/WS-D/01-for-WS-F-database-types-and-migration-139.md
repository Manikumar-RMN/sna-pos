# WS-D -> WS-F: database.types.ts, migration 139, README, go-live

## 1. app/src/lib/supabase/database.types.ts (Functions block, alphabetical position)
The WS-D code calls these RPCs through the typed client (`supabase.rpc("...")`), so the build needs these entries.

```ts
      bulk_price_apply: {
        Args: {
          p_client_ref?: string
          p_expect_lines?: number
          p_include_branch: boolean
          p_mode: string
          p_reason: string
          p_rounding: number
          p_scope: Json
          p_value: number
        }
        Returns: Json
      }
      bulk_price_history: {
        Args: { p_limit?: number }
        Returns: Json
      }
      bulk_price_preview: {
        Args: {
          p_include_branch?: boolean
          p_mode: string
          p_rounding?: number
          p_scope?: Json
          p_value: number
        }
        Returns: Json
      }
      bulk_price_undo: {
        Args: { p_batch: string; p_reason?: string }
        Returns: Json
      }
      copy_role_rights: {
        Args: { p_from_role: string; p_mode?: string; p_to_role: string }
        Returns: Json
      }
      copy_staff_access: {
        Args: { p_from_user: string; p_to_user: string }
        Returns: Json
      }
      log_print: {
        Args: { p_kind: string; p_order: string; p_ticket_ids?: string[] }
        Returns: Json
      }
```

Tables (Tables block). Only needed if some screen reads them directly; WS-D reads history through `bulk_price_history`, so these are optional but keep the file complete.

```ts
      price_change_batches: {
        Row: {
          branch_id: string | null
          client_ref: string | null
          created_at: string
          created_by: string | null
          id: string
          include_branch: boolean
          line_count: number
          mode: string
          reason: string
          restaurant_id: string
          rounding: number
          scope: Json
          status: string
          undo_restored: number | null
          undo_skipped: number | null
          undone_at: string | null
          undone_by: string | null
          value: number
        }
        Insert: never  // written only by the definer functions
        Update: never
        Relationships: []
      }
      price_change_lines: {
        Row: {
          batch_id: string
          branch_id: string | null
          id: number
          new_price: number
          old_price: number
          product_id: string
          restaurant_id: string
          scope: string
          undo_state: string | null
        }
        Insert: never
        Update: never
        Relationships: []
      }
```
(If the file's generator style uses `Insert: { ... }`, copy the style of another read-only table such as `audit_logs`.)

## 2. Migration 139 (integrator)
- Permissions: WS-D adds NO new permission rows. `order.reprint`, `menu.price_change`, `user.manage` already exist and are granted.
  - `order.reprint` stays with Cashier / Chef / Manager / Owner. Stewards do NOT get it (founder decision): they ask a manager for a PIN. Do not grant it to Steward in 139.
  - `order.open_price` (key added to `lib/permissions.ts` by WS-D, Billing group): 139 (or 131 if WS-C inserts it) must `insert into public.permissions (key, description, is_sensitive) ... on conflict do nothing` and grant to Owner and Manager roles only (pattern of 034/039).
- erase_groups(): add the two WS-D tables to `pos_master`, before `'products'` (lines first, then batches):
  `'price_change_lines', 'price_change_batches'` (suggested position: right after `'product_price_history'`).
  Both cascade from products/restaurants, so the order is safe either way.

## 3. supabase/migrations/README.md
Add rows: 135 log_print / reprint audit, 136 bulk price change (tables price_change_batches, price_change_lines + bulk_price_preview/apply/undo/history, guard_product_change replaced with the bulk flag), 137 copy_role_rights / copy_staff_access. Rollback notes are at the top of each file.

## 4. Go-live script
135, 136, 137 are independent of 130-134 and 138. 136 CREATE OR REPLACEs `app.guard_product_change()` (033 body + the `app.bulk_price` flag): in a go-live file keep the whole of 136 in the one transaction. 136 creates tables, so it is NOT re-runnable; guard the file with the same "refuse if already recorded" check you use for the other go-live files.
Test: `docs/tests/run-t135-137.sh` (replays every migration <= 137 that exists in the checkout, then `docs/tests/t135-137.sql`; 92 checks). If 138/139 are merged first it still runs (it only replays <= 137).

## 5. Nav / sections
No new nav item. The bulk price screen is reached from Settings > Menu (link added by WS-D in `settings/menu/page.tsx`, shown with `menu.price_change`). Route: `/settings/menu/bulk-price`.
Security profiles and Users pages got the copy controls in place (no new routes).
