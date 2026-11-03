# Charging a POS bill to a hotel room (design, not built)

Status: **not implemented.** Written 2026-11-03 so the work can be done safely once `npm run test:e2e` can run.

## Why it is not in migrations 152–157

A "Charge to room" payment is the same shape as "Charge to account" (migration 100): the bill is marked paid by a hidden
payment, and the amount lands on someone's tab instead of the till. Everything that already special-cases the `account`
payment kind has to learn the new kind, otherwise a voided or credited bill leaves money stranded on a folio:

| Where the `account` kind is handled today | What a `room` kind needs |
|---|---|
| `payment_methods_kind_check` (064, 098, 100) | add `'room'` to the list |
| `app.guard_redeem_payment` (100, 124) | refuse a `room` payment unless `app.room = 'on'` |
| `void_order` reversal (120, section 1) | void the matching `fo_charges` row when the bill is voided |
| credit note onto an account (120, ~l.298–342) | credit back to the folio, capped at what is still on it |
| `account_settle` / gift-card / advance method pickers (101, 117, 122) | exclude `room` from "how did the guest pay" |
| erase-groups (139, 148) | include `fo_charges.order_id` in what a bill erase touches |
| brand settlement, chain report (102, 120) | decide whether a room charge counts as collected |

Changing those live functions without the 61-test money-path suite would be guessing.

## Proposed shape

1. `app.room_method(restaurant)` creates the hidden method (kind `room`, not in the drawer), as `app.account_method` does.
2. `public.fo_charge_bill_to_room(p_order, p_stay)`: needs `payment.take` (a cashier, not `fo.manage`) and the `front_office` module.
   The stay must be in-house in the same restaurant. Inserts the hidden payment with `app.room = 'on'`, marks the bill paid,
   and inserts an `fo_charges` row with `order_id` set.
3. **Tax is not charged twice.** The POS bill already carries its GST and is reported on the POS return, so the folio line
   is `net = bill total, tax = 0`, described "Restaurant bill #N (tax included)".
4. **Revenue is not counted twice.** `fo_night_audit_run` must leave order-linked charges out of `other_revenue`
   (that revenue is already in the POS sales reports). The Day-end and MIS modules must do the same.
5. Voiding the bill voids the folio charge (reason copied); once the folio is checked out the bill can only be credit-noted.
6. A guest checking out with a room-charged bill needs no special handling: the charge is an ordinary folio line.

## Tests to write first (extend `app/e2e`, run with `npm run test:e2e`)

charge-to-room on a part-paid bill; refuse when the stay is not in-house; refuse for another restaurant's stay; void bill
reverses the folio line; credit note larger than the line is refused; folio balance after each; day-close totals unchanged
by a room charge; a Cashier can charge to room but cannot post a manual folio charge.
