# Browser tests of the real app

`npm run test:ui` (in `app/`) — 71 tests, about 3 minutes (the first run builds the app).

## What it runs

Everything is real except Supabase's sign-in service, and all of it is local and throw-away:

```
Chromium (a real browser)  ->  the real Next.js production build  ->  a thin gateway  ->  real PostgREST  ->  real PostgreSQL
                                                                      (sign-in only)                          (every migration replayed)
```

* **PostgreSQL** is built fresh from `supabase/migrations` (same as `app/e2e`).
* **PostgREST** is the real program Supabase uses for its REST API, so row-level security, grants and views behave exactly as in production.
* The **gateway** (`support/authlite.ts`) answers only the four calls the app makes to Supabase Auth (password sign-in, refresh, "who am I", sign-out),
  checking passwords with pgcrypto against `auth.users` like Supabase does, and passes everything else to PostgREST.
  It also writes down every database request that failed, so a test can see what a screen asked for and was refused.
* The **app** is `next build` + `next start` with the gateway as its Supabase address.

## Setup once

```
npm install
e2e-ui/fetch-postgrest.sh        # downloads the PostgREST binary (5 MB) into app/.tools/ (not in git)
```
Needs PostgreSQL 16+ **server** binaries (`initdb`, `pg_ctl`) and Chromium (`PLAYWRIGHT_BROWSERS_PATH`, default `/opt/pw-browsers`).
Without them the tests skip and say so. `E2E_SKIP_BUILD=1` reuses the last build; `E2E_LAST_MIGRATION=114` builds the database only
up to that migration (to prove a test would have caught a bug).

## What the tests do

| File | Real-browser checks |
|---|---|
| `login.ui.test.ts` | Staff sign-in by client code + staff code; the same vague message for every wrong detail; sign-out; five wrong passwords lock the person out; a deactivated person cannot sign in |
| `billing.ui.test.ts` | The cashier sees the menu and prices; the cart's subtotal, GST, rounding and total; minus and Clear; a cash bill with change, the receipt (CGST/SGST lines, tendered, change) and the database record; consecutive bill numbers; UPI with its reference; a dine-in bill saved to the kitchen then paid from the bill screen; menu search |
| `manager.ui.test.ts` | A cashier's void asks for a manager's PIN and changes nothing; the manager's PIN typed on the cashier's screen approves it and is audited; a wrong PIN is refused; manager void with a reason; refund as a numbered credit note, capped at what was paid; another restaurant's staff cannot open a bill by its address; signed-out visitors are sent to login; day close (blocked by an unpaid bill, then done; the next bill belongs to the next day) |
| `offline.ui.test.ts` | The till copies the menu, goes offline ("paid bills only"), queues bills with their own numbers, sends them by itself when the internet returns; a tampered price is corrected, reported to the owner and shown to the manager (not the cashier); a discount without the right is not honoured; a refused bill does not block the next one and is kept on the device |
| `screens.ui.test.ts` | Every screen of the app (44) opens as the owner with no error page, no browser error and **no refused database request**; the receipt, bill and kitchen-ticket screens for a real bill |

## What this found

* **The billing screen was empty for every signed-in user on the live database** (Pre-orders and the Captain app too): migration 094 made the menu view call a
  function that signed-in users may not run. Fixed by migration 115. The screen sweep fails on a database without it.

## What it does NOT cover

* Real Supabase Auth (e-mail confirmation, password reset by e-mail, rate limits), real e-mail, push, WhatsApp, printers.
* Phones and tablets (it runs a 1280x900 desktop window), other browsers, slow networks, the Captain app's and kiosk's own flows beyond opening.
* Stock, purchases, loyalty, reservations, deliveries, pre-orders, kiosk: the screens open, but their actions are not exercised.
* Visual design. Only text, behaviour and data are checked.
