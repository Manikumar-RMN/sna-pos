# database.types.ts (WS-F): two new RPCs

Target: `app/src/lib/supabase/database.types.ts`, inside `Functions: { ... }` (alphabetical placement: `floor_status` after `fire_held_items`,
`move_order_items` before `move_order_table`). WS-B's code calls both through a loose cast, so nothing breaks before this is added; once added,
the casts in `floor/load-floor.ts` and `bills/move-item-actions.ts` can be replaced with plain `supabase.rpc(...)` calls (optional).

```ts
      floor_status: {
        Args: Record<PropertyKey, never>
        Returns: {
          table_id: string
          table_number: string
          seats: number
          open_bills: number
          open_total: number
          oldest_open_at: string | null
          kot_waiting: number
          oldest_kot_at: string | null
          reservation_id: string | null
          reservation_at: string | null
          reservation_name: string | null
          reservation_party: number | null
          db_now: string
        }[]
      }
      move_order_items: {
        Args: {
          p_order_id: string
          p_items: Json
          p_to_table: string
          p_client_ref?: string
        }
        Returns: Json
      }
```

`move_order_items` returns (Json): `order_id, bill_number, grand_total` (source bill), `to_order_id, to_bill_number, to_grand_total, to_table`,
`new_bill` (bool), `lines_moved`, `total_before`, `total_after`, `unrounded_before`, `unrounded_after`, and `repeat: true` on a replay.
