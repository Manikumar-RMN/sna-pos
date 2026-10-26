# Menu fields (WS-DB -> WS-M), migration 141

- `products.discount_restricted boolean not null default false` ("Do not allow discounts on this item") and `products.prep_minutes smallint null` (check 1..240; the database refuses 0 and 241 with
  `products_prep_minutes_range`). Both are plain columns: `updateProduct` can `update public.products set ...` under the existing menu right; there is no new RPC.
- Sizes (rows with `parent_id`) follow their dish: saving the dish copies both values to every size (trigger `trg_product_variant_follow`). A size can also be edited on its own; the bill uses the size's value first.
- Audit: changing the flag writes `menu.discount_flag` (new_value `{name, discount_restricted}`, old_value `{discount_restricted}`), changing the prep time writes `menu.prep_time`; only for dishes (not for sizes), only when the value really changed.
- The flag is **copied onto the bill line** when the line is created (`order_items.discount_blocked`); changing the flag later never changes bills already taken.
