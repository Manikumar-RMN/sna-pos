# WS-C -> WS-A (and WS-D): open-priced item at the till
DB (migration 131, WS-C, done): `products.is_open_price`, `bill_input` accepts `price` on a line for such a product and needs the role right `order.open_price` (Owner, Manager). The refusal text is "Only a manager or owner can enter a price for X. ..." and deliberately does NOT contain "(order.open_price)": the app's ApprovalPrompt (error text with "(perm.key)") must not appear, because no PIN can be taken inside the billing function.

## WS-A: pos/menu-data.ts `loadMenu`
Add `is_open_price` to the products query that already adds `sold_by` / `barcode`, expose it on `MenuItem` as `is_open_price?: boolean` (additive).

## WS-A: pos/pos-terminal.tsx
- When an item with `is_open_price` is tapped: skip the normal add and open a small price prompt (number, > 0, 2 decimals, show the name; Enter adds the line). The cart line carries the typed price: `{ product_id, qty, price }`. A different typed price = a different cart line (do not merge lines with different prices). Show it in the cart as "Open price".
- Send `price` ONLY for open items. For every other item do not send a price (the server ignores it anyway).
- `quoteOrder` and `placeOrder` / `addToBill` already pass the item JSON through; make sure the mapping that builds the RPC items (pos/actions.ts) copies `price` when present.
- Only show the item to people who may use it: hide or disable it when `!can(user, "order.open_price")` (the server refuses anyway).
- Offline snapshot mode and QR / online / pre-order menus: hide open items or show "needs internet and a manager". `app.bill_input` refuses them there (no signed-in user with the right).

## WS-D: settings/menu/page.tsx (the file that lists products for MenuManager)
Add `is_open_price` to the `.select("id, name, price, ... track_batches")` list at line ~16 so the toggle in menu-manager shows its current state:
`...sold_by, barcode, track_batches, is_open_price`.

## WS-D: lib/permissions.ts
```ts
// key: "order.open_price"  label: "Enter the price of open-priced items at the till"  group: same group as "order.discount" / "menu.price_change" (sensitive)
```
Seeded for Owner and Manager by migration 131 (idempotent; migration 139 may repeat the grant with ON CONFLICT DO NOTHING).
