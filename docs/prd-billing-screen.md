# SNA POS — PRD: Billing Screen (V1)

**Owner:** Product Manager · **Status:** Draft for Founder approval · **Date:** 23 Sep 2026
**Replaces:** the "POS Billing" line item in the RPOS UX Specification v1.0

---

## Plain-language summary

This is the one screen the whole product lives or dies on. A cashier stands at it
during the lunch rush and has to turn an order into a printed bill in under ten
seconds, with or without internet. Everything below exists to make that true.

---

## 1. Problem

Small restaurants bill on paper pads, a dumb billing machine, or a POS built for
chains. Paper means the owner cannot see the day's sales without adding up
by hand. Chain software is too expensive, too slow to learn, and stops working
when the internet drops — which, at a roadside restaurant in Karaikudi, it does.

**Evidence status:** **Founder-validated**, 23 Sep 2026. The Founder has worked on
POS in this market and is the domain authority for SNA POS. Customer interviews are
deliberately skipped.

*Recorded risk:* this makes the product's direction dependent on one person's read
of the market. The cheap insurance is to show the first working build to three real
restaurant owners before the pilot — not to validate the idea, but to catch
workflow details a spec always misses. Founder's call.

## 2. Goal and success metric

**Goal:** a cashier who has never used SNA POS can take a 5-item dine-in order and
print a correct bill within 10 minutes of first opening the app.

| Metric | Target |
|---|---|
| Time from first tap to printed bill (experienced cashier, 5 items) | under 20 seconds |
| Taps to add one item to the cart | 1 |
| Bills that fail to print on the first attempt | under 2% |
| Bills lost when the internet drops | **0** |
| Arithmetic errors in a bill total | **0** |

## 3. Who uses it

| Person | What they need |
|---|---|
| **Cashier** | Speed. Nothing else matters to them. |
| **Waiter** | Send the order to the kitchen from the floor, pay later |
| **Owner** | Confidence that no bill was cancelled behind their back |

## 4. User stories

1. As a **cashier**, I want to add a menu item with one tap so I can keep up with
   a queue.
2. As a **cashier**, I want to search the menu by typing two or three letters so I
   can find an item without hunting through categories.
3. As a **cashier**, I want to change quantity without deleting and re-adding the
   item.
4. As a **cashier**, I want to see the running total at all times so I can answer
   "how much?" without finishing the order.
5. As a **cashier**, I want to keep billing when the internet is down, and know my
   bills are safe.
6. As a **waiter**, I want to attach an order to a table and send it to the
   kitchen without taking payment.
7. As a **cashier**, I want to attach a customer's phone number so the owner can
   contact them later.
8. As an **owner**, I want every discount and every void to record who did it and
   why.
9. As a **cashier**, I want the bill to print automatically once payment is
   confirmed.
10. As a **cashier in Dubai**, I want the bill to say VAT, not GST, without anyone
    changing the software.

## 5. Acceptance criteria

**Adding items**
- Given the billing screen is open, when the cashier taps a menu tile, then the
  item is added to the cart and the total updates in under 200ms.
- Given an item is already in the cart, when the cashier taps the same tile again,
  then the quantity increases by 1 — a second line is never created.
- Given the cashier types 2+ characters in search, then matching items appear in
  under 300ms, matching on name and short name.

**Money**
- Given items are in the cart, then subtotal, discount, each tax component and
  grand total are shown separately and always add up exactly.
- Given the branch's tax group is tax-exclusive, then tax is added on top of the
  menu price.
- Given the branch's tax group is tax-inclusive, then tax is shown as contained
  within the menu price and the grand total equals the sum of menu prices.
- Given a bill is in India and the sale is within the state, then CGST and SGST
  print separately. Given it crosses states, IGST prints instead.
- Given a bill is in the UAE, then a single VAT line prints. **No code change.**
- All money is calculated to 2 decimal places. Rounding happens once, at the
  grand total, using the branch's rounding setting.

**Discounts and voids**
- Given the cashier does not hold `order.discount`, when they tap Discount, then
  they are asked for a manager PIN.
- Given a discount is applied, then the approving user and the reason are stored
  against the order.
- Given a bill is completed, when anyone tries to change its amount, then the
  system refuses and offers Void or Refund instead.
- Given a bill is voided, then a reason is required and the original bill remains
  visible in reports, marked Voided.

**Offline**
- Given there is no internet, when the cashier takes an order, then the bill is
  created, numbered, saved and printed exactly as if online.
- Given a bill was created offline, then the screen shows a "pending sync" count.
- Given the internet returns, then pending bills upload automatically and the
  count drops to zero without the cashier doing anything.
- Given the same offline bill is uploaded twice, then it appears **once**. No
  duplicate bills, ever.
- Given two tablets bill offline at the same time, then their bill numbers never
  collide.

**Printing**
- Given payment is confirmed, then the receipt prints automatically.
- Given printing fails, then the cashier sees a clear retry option and the bill is
  still saved.
- Receipts render correctly on both 58mm and 80mm thermal paper.

**Permissions**
- A cashier can: create orders, take payment, reprint.
- A cashier cannot: void a bill, change a menu price, view profit reports, export
  the customer list.

## 6. Out of scope for V1

Moved to the V2 backlog, and not to be promised to any customer:
inventory and stock deduction · recipes · purchase orders and suppliers · online
order aggregators (Swiggy, Zomato, Talabat) · loyalty points and wallet · table
QR self-ordering · multi-outlet consolidated reporting · accounting software sync ·
split bills across multiple tables · staff tips and payroll · government e-invoice
certification for Saudi Arabia.

**Note on the last one:** Saudi Arabia legally requires a certified e-invoice from
the POS itself. Until that certification exists, SNA POS cannot be sold there. The
database records this per country so the app can block it.

## 7. Data touched

From `sna_pos_schema_v2.sql`:

| Table | Use | Sensitivity |
|---|---|---|
| `products`, `categories`, `modifier_items` | Menu display | Low |
| `orders`, `order_items`, `order_item_modifiers` | The bill | **High — money** |
| `order_item_taxes` | Frozen tax breakdown | **High — tax filing** |
| `order_discounts` | Who approved what | **High — fraud risk** |
| `payments` | Amounts taken | **High — money** |
| `customers` | Phone, name | **High — personal data (DPDP Act)** |
| `kitchen_tickets` | KOT | Low |
| `shifts`, `cash_movements` | Day close | **High — cash** |
| `audit_logs` | Every sensitive action | **High** |

Card numbers are never stored. Customer phone numbers are personal data under
India's DPDP Act 2023 and need a stated purpose and a deletion route.

## 8. Open questions for the Founder

1. **Can a cashier sign in with a 4-digit PIN on a shared tablet, or must every
   person have their own login?** PIN is far faster and is what restaurants
   expect. Full logins are more secure. Recommendation: PIN for floor staff, full
   login for owner and manager. The schema supports both.
2. **Should a bill be printable before payment** (the "show me the bill" moment in
   Indian dine-in), or only after? Recommendation: yes, print an unpaid bill, marked
   clearly as not a tax invoice.
3. **Is the first market India only?** The schema is country-agnostic either way,
   but it changes what Legal has to check before selling.
4. **Which SNA POS Agent job ships first?** See `agent-architecture.md` §"What I
   need from the Founder". Recommendation: the owner's analyst, read-only.

## 9. Hand-offs

UX/UI Designer (tablet layout, §4.1 of the design doc) → System Architect +
Security Engineer (offline sync design) → Engineering Lead (task breakdown) →
QA Engineer (test plan from §5) → Documentation Writer.

The SNA POS Agent is a separate track and must not block this one — see
`agent-architecture.md`. Billing ships whether or not the agent is ready.

## 10. Definition of done

Every acceptance criterion in §5 passes, QA signs off, the Security Engineer signs
off on the offline sync and permission checks, and a real cashier — not a member of
the team — bills 20 orders on a tablet without asking for help.
