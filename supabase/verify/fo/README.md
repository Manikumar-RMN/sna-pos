# Front Office tests (migrations 160–164)

`./run_fo_tests.sh` starts a throw-away PostgreSQL, replays every migration, builds a hotel with an owner and a
cashier through the real tenant-creation function, and then exercises the money paths as a signed-in user
(`set role authenticated` plus the person's id in `request.jwt.claims`, exactly as the app connects).

It needs PostgreSQL 16+ server binaries and nothing else — no npm, no Supabase project, no network. Nothing outside
a temp folder is touched.

66 checks, covering: module gating, a Cashier being refused, room and room-type masters, guest de-duplication by
phone, the availability calculation, check-in rules (clean / not out of service / free for the whole stay), charge
tax, retry idempotency on `client_ref`, voids needing a reason, check-out refusing an unpaid or in-credit folio,
collect-and-close in one call, cancellation against an advance, out-of-service needing a reason, the night audit
(room charges, GST slab, ADR / RevPAR / occupancy, no-shows, no second run) and tenant isolation under RLS.

Run it after changing anything in 160–164:

    supabase/verify/fo/run_fo_tests.sh

Expected last line: `total 66, failed 0`.

A vitest version under `app/e2e/` would let `npm run test:e2e` cover this too; it is not written yet because the
sandbox these were authored in could not reach the npm registry.
