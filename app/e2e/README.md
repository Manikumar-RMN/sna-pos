# End-to-end tests of the money path

`npm run test:e2e` (in `app/`) — 61 tests, about 10 seconds.

## What they do

They start a **throw-away PostgreSQL** in a temp folder, load stand-ins for what Supabase provides, replay **every migration**
(`supabase/migrations`), then drive the **real database functions as real signed-in people** (an owner, a manager, a cashier,
and a second restaurant). All the money rules live in those functions; the app's server actions only call them.
Nothing touches your live database.

| File | What it proves |
|---|---|
| `tenancy.e2e.test.ts` | One restaurant cannot see, void, refund, pay or bill another's data; nobody can write to bills, payments, credit notes, roles or the audit log directly; a signed-out visitor can do nothing; a cashier cannot do manager things |
| `billing.e2e.test.ts` | The database total equals the app's own calculator to the paisa (8 carts, discount, service charge); a price sent from the browser is ignored; bad quantities refused; cash change, UPI reference, part payments; a paid bill cannot be paid again; double-tap and retry are safe; add / cancel / split / merge / discount; void, credit notes (partial, full, never more than paid), immutability, audit trail |
| `day.e2e.test.ts` | Shift cash: expected = float + cash sales - paid out, variance exact, owner told of a shortage; the day cannot close with an unpaid bill; the day report equals the bills, tax and payment modes; a closed day is frozen; refunds after close are credit notes on the day given; reopen rules |
| `concurrency.e2e.test.ts` | 30 tills at once: unique, gap-free bill numbers; 10 taps of one bill = one bill and one payment; 6 tills paying one bill = paid once; 8 people adding items = every item once; 6 managers refunding at once = never more than was paid |
| `offline.e2e.test.ts` | Offline bills: honest ones recorded exactly; retries never duplicate; wrong or reused numbers refused; a price the menu never had is corrected and reported; a price that was right when the till last copied the menu is accepted; a discount without the right is removed; unknown payment method, clock ahead, and total mismatch are reported; an old till time cannot put a bill in a closed day |

## What they do NOT cover

- The screens (React) and the server actions in `app/src`. They are thin, but nothing here clicks them.
- Supabase's own services (sign-in, the REST layer). The tests call the database functions directly, with the person's id set as Supabase does.
- Printing, WhatsApp, e-mail, push alerts, the kitchen display, stock, purchases, loyalty, kiosk, captain, reservations.
- Load. 30 simultaneous bills is a race check, not a performance test.

## Needs

PostgreSQL 16 or newer **server** binaries (`initdb`, `pg_ctl`). Without them the tests skip and say so. Runs as `root` too (it
switches to the `postgres` user for the throw-away server).
