# Points as a discount on the bill screen (WS-DB -> WS-A2); privacy change for direct reads

## RPCs (145). Needs right `loyalty.redeem` (Owner, Manager, Cashier by default; Steward/Chef do not have it). Error text for a missing right: "Your role does not allow this action (loyalty.redeem)."
- `redeem_points_discount(p_order uuid, p_points numeric, p_client_ref uuid default null) -> jsonb`
  `{points_used, discount, grand_total, points_left}` (+ `repeat: true` when the same `p_client_ref` is sent again: nothing is charged twice). Use one uuid per button press.
  The server may use FEWER points than asked: it cuts to what the bill can take (the discountable part less the typed discount, `max_redeem_percent`, never more than is due) and returns `points_used` / `discount`.
  Refusals (show the text as is): "Add the guest's phone number to the bill first." / "Set up loyalty points in Settings first." / "This outlet redeems points as a payment, not as a discount." /
  "This bill has a senior citizen / PWD discount; points cannot be used on it." / "Points are already used on this bill. Remove them first to use a different amount." /
  "Enter the points to use." / "The guest has only 20.00 points." / "At least 10 points must be used at a time." / "Nothing on this bill can be discounted with points." /
  "Bill X already has a payment, so points cannot be used as a discount on it." (any payment, also a part payment).
- `remove_points_discount(p_order uuid) -> jsonb` `{points_returned, grand_total, points_left}`; "No points have been used on this bill." when there is nothing to remove.
- The old `redeem_points(order, points)` (points as a PAYMENT) is refused when the outlet is in discount mode ("This outlet redeems points as a discount on the bill."); in tender mode it works as before.
- `loyalty_settings` (readable by every signed-in user): `redeem_mode` ('tender' default, or 'discount'), `max_redeem_percent`, `point_value`, `min_redeem`, `spend_per_point`. Show the discount button only when `redeem_mode = 'discount'`.
- The points follow the bill: if a line is cancelled and the discountable part shrinks, the points discount is lowered and the surplus points are returned automatically ("Bill changed" adjust row);
  `orders.calc_params.loyalty_discount / loyalty_points` and the `order_discounts` row (type `loyalty_points`) stay in step. Re-read the bill after any item change.
- Approval prompt label for `loyalty.redeem`: the database text above contains "(loyalty.redeem)" so `approval.tsx` can map it.

## Direct table reads changed (privacy)
`customers` and `loyalty_ledger` are now readable only by users with `customer.view` OR `customer.manage` (before: every signed-in user, phone numbers included). `bill-screen` reads that go straight to those tables
return **zero rows** for a role with neither right (for example a Chef) - not an error. For the bill screen use the definer RPCs instead:
- `find_customer(p_phone)` (needs `order.create` only): `{id, name, visits, last_visit_on, points}` or null (matches the last 10 digits, so +91 / leading 0 do not matter; fewer than 7 digits -> null). No phone, no spend.
- `attach_customer(order, phone, name)` still returns `{customer_id, name, phone, points}`; `set_order_guest` unchanged.
- A bill's points: `app.points_balance` is not callable by the app; use `find_customer(...)->points`, the result of `attach_customer`, or `customer_detail(p_customer)` (needs customer.view) for the history.
