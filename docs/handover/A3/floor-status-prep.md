# floor_status: preparation-time columns (WS-DB -> WS-A3), migration 142

`public.floor_status()` keeps its 13 columns (same names, order, filter) and adds 3 at the END:

| column | type | meaning |
|---|---|---|
| `kot_due_at` | timestamptz | when the kitchen ticket that is due FIRST becomes late; null when no ticket is waiting |
| `kot_prep_min` | integer | the longest `prep_minutes` among that ticket's live (not cancelled) lines; **null when no line has a prep time** |
| `kot_ticket_at` | timestamptz | start of that ticket (`coalesce(client_created_at, created_at)`) |

Rule: `kot_due_at = kot_ticket_at + (kot_prep_min + 5 minutes grace)` when `kot_prep_min` is not null, else `kot_ticket_at + 15 minutes` (no grace). A line's prep time is its size's `prep_minutes`, else its dish's.
Constants: `app.kot_grace_min() = 5`, `app.kot_default_min() = 15` (so `PREP_GRACE_MIN = 5` and `KOT_DELAYED_MIN = 15` in `lib/table-status.ts`).
`lib/table-status.ts`: a table is `kot_delayed` when `now > kot_due_at`; when the row has none of the new columns (older database) keep the fixed 15 minutes on `oldest_kot_at`.
`oldest_kot_at` and `kot_waiting` are unchanged (oldest waiting ticket / count). The ticket reported is the one due first, which may not be the oldest.
Needs `order.create` as before. Regenerate types: `database.types.ts` already has the three columns.
