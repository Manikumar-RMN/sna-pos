# WS-A2 notes for WS-DB / WS-P

RPC names and argument names used by app/src/app/(app)/bills/actions.ts (called through a loose `rpc` wrapper until database.types.ts is regenerated; after regeneration the wrapper can be replaced by `supabase.rpc(...)`):

- `find_customer(p_phone text)` -> jsonb `{id, name, visits, last_visit_on, points}` or null
- `redeem_points_discount(p_order uuid, p_points numeric, p_client_ref uuid)` -> jsonb `{points_used, discount, grand_total, points_left}`
- `remove_points_discount(p_order uuid)` -> void/jsonb (result not read)

Columns read by bill-screen.tsx: `order_items.discount_blocked`, `loyalty_settings.redeem_mode`, `loyalty_settings.max_redeem_percent`, `orders.calc_params.loyalty_points / loyalty_discount`.

Rights: `loyalty.redeem` is only reached through the server error text "(loyalty.redeem)" (PIN prompt). The panel itself is shown to users with `payment.take`, as before.
