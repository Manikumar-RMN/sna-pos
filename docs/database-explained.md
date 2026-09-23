# SNA POS — Database v2.0, Explained in Plain Language

**Owner:** Backend Engineer + System Architect · **Reviewed by:** Security Engineer
**Date:** 23 Sep 2026 · **Replaces:** RPOS Database Structure v1.0
**The actual file:** `sna_pos_schema_v2.sql` — 37 tables, tested and working

---

## For the Founder, in one minute

Your old database document listed about 60 tables. It was a good inventory but it
was a list, not a database — no developer could have built from it, and three
things in it would have caused serious problems later. All three are now fixed,
and the new version has been **run on a real database and tested**, not just
written out.

| | Old (RPOS v1.0) | New (SNA POS v2.0) |
|---|---|---|
| Could restaurant A see restaurant B's data? | **Yes** | No — blocked by the database itself |
| Could it work outside India? | No — Indian GST was built into the structure | Yes — India, UAE, Saudi, Singapore all tested |
| Could someone quietly change yesterday's takings? | Yes | No — refused by the database |
| Could a bill be deleted? | Yes | No — only voided, with a reason and a name |
| Were passwords safe? | Stored in plain text | Never stored by us at all |
| Had it been tested? | No | Yes — every rule below was run and proved |

---

## The three problems that were fixed

### Problem 1: every restaurant could see every other restaurant's data

In the old design, tables like `categories`, `products`, `customers` and `taxes`
had no column saying **which restaurant they belonged to**. So the moment you had
two paying customers, restaurant A's menu, customer phone numbers and sales would
have been visible to restaurant B.

This is the kind of problem that ends a SaaS business. It is also very expensive to
fix after launch, because by then real data is sitting in the wrong shape.

**The fix.** Every business table now carries a `restaurant_id`. On top of that,
the database has **Row Level Security** switched on for all 37 tables — a rule
enforced by the database, not by the app. Even if the app has a bug, or someone
finds a way to ask the database directly, they still only get their own rows.

**Proved, not assumed.** We created two restaurants — one in Karaikudi, one in
Dubai — and signed in as each owner:

- The Dubai owner asked for the Indian restaurant's menu **by its exact internal
  ID**. Result: `0 rows`.
- The Dubai owner tried to insert a category into the Indian restaurant. Result:
  `ERROR: new row violates row-level security policy`.

### Problem 2: it only worked in India

The old design had `taxes(id, tax_name, cgst, sgst, igst)`. CGST, SGST and IGST are
Indian GST terms. A restaurant in Dubai pays VAT. In Singapore it is GST but at a
different rate with no split. You said you want to sell in multiple countries, and
that structure made it impossible without rebuilding.

**The fix.** Tax is now three small tables instead of three fixed columns:

- **Tax group** — what the owner picks on a menu item ("Food 5%")
- **Tax rate** — what that group means, valid between two dates
- **Tax components** — how it breaks down on the printed bill

The same three tables cover every country tested:

| Country | What the owner sets up | What prints on the bill |
|---|---|---|
| India (same state) | Food 5% | CGST 2.5% + SGST 2.5% |
| India (other state) | *same setup* | IGST 5% |
| UAE | Food 5% | VAT 5% |
| Singapore | Food 9% | GST 9% |
| Saudi Arabia | Food 15% | VAT 15% |

**Adding a country becomes data entry, not a rebuild.** That was the whole point.

There is a second thing this fixes. Menu prices in India are usually quoted
*before* tax; in the UAE they are usually quoted *including* tax. That is now a
setting per tax group. Getting it wrong makes every single bill wrong, so it must
never be an assumption in code.

**One warning.** Saudi Arabia legally requires a government-certified e-invoice
from the POS itself. That is a project of its own. The database records which
countries need it so the app can refuse to go live there until it is done — but
**SNA POS cannot be sold in Saudi Arabia until that certification exists.** Do not
let a salesperson promise it.

### Problem 3: nothing protected the money

A POS is a machine that counts money. Staff theft in restaurants usually works by
deleting or reducing bills after the fact. The old design had nothing to stop it.

**The fix.** Four rules, enforced by the database:

1. **A closed bill's amounts cannot be changed.** Tested: an attempt to reduce a
   ₹105 bill to ₹5 was refused with *"Bill MN-C1-0001 is closed and its amounts
   cannot be changed."*
2. **Bills and payments can never be deleted.** Tested: refused.
3. **A void needs a reason and a name.** Tested: voiding without a reason was
   refused; voiding with "Customer cancelled" and the user's ID succeeded, and the
   original bill stays visible in reports marked Voided.
4. **Every discount records who approved it.** Discounts are the most common route
   for till fraud, so this one is not optional.

On top of that, item names and prices are **copied onto the bill at the moment of
sale**. If the owner renames a dish or raises a price tomorrow, last week's bills
do not change. In the old design they would have.

---

## Two more things that were added

### It now works without internet

This was missing entirely, and for a restaurant POS it is the single hardest
requirement. A bill must be takeable when the connection drops.

Three changes make it possible:

- **Bill IDs are created on the tablet, not on the server.** A bill taken offline
  already has its final identity, so when it uploads later it updates that exact
  row. It can be sent twice and it still appears once. No duplicate bills.
- **Each tablet has its own bill number prefix and counter**, so two tablets
  billing offline at the same counter can never produce the same bill number.
- **Two timestamps on every bill**: when the cashier actually billed, and when the
  server first saw it. Offline, these differ — and the day-end report must use the
  first one, or the money will not match the drawer.

### Passwords are no longer stored

The old design had `users(..., password, pin)` with no note on how either was
protected. Storing a password in a database at all is a serious risk.

Now: passwords live in Supabase Auth, hashed, and never touch our tables. The
4-digit PIN that floor staff use on a shared tablet is stored only as a bcrypt
hash. Card numbers are never stored anywhere — that is the payment provider's job,
and storing them would break card industry rules.

---

## What is deliberately left out

The old document listed inventory, recipes, purchase orders, suppliers and loyalty
— about 25 tables' worth. All of it is real and all of it belongs in the product
**eventually**. None of it is in V1.

A small restaurant needs to bill, print, take payment and close the day. That is
what V1 does, and it is the difference between shipping in 5 months and shipping in
14. Everything else is in the V2 backlog where it can wait without cluttering the
build.

---

## What still needs a human

Three things AI should not sign off alone:

1. **A human developer** must review this schema before it is applied to a real
   database. It has been tested, but tested is not the same as reviewed.
2. **A chartered accountant** must confirm the Indian GST rates and the tax
   registration fields before a single real bill is issued.
3. **An independent security tester** must attack the live system before the first
   paying customer, not after.

---

## How to use the SQL file

Give `sna_pos_schema_v2.sql` to the developer with this document. They will run it
on a fresh, empty Supabase project — never on one with data in it. It creates
everything: tables, security rules, protective rules, and the starting reference
data for currencies, countries and permissions.

Nothing in it deletes or modifies anything that already exists.
