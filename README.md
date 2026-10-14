# SNA POS

A point-of-sale system for small restaurants, built to be sold in more than one
country. A product of **SNA.AI**.

> **Status: in development.** The database is live; the application is not built
> yet. Nothing here has been reviewed by a human developer, and no restaurant is
> using it. Do not put real customer data in it.

---

## What this repository holds

| Path | What it is |
|---|---|
| `supabase/schema/01_schema.sql` | The full database — 37 tables, Row Level Security, and the rules that protect the money |
| `supabase/schema/02_agent.sql` | The SNA POS Agent: its tables and its read-only database role |
| `supabase/schema/03_live_baseline.sql` | The live database as it stands on 13 Oct 2026 (100 tables, 331 functions, RLS, grants), in one file. **Not** to be run on the live one. Supersedes 01 and 02 |
| `supabase/migrations/` | All 114 migration files (001-113) in order, rebuilding the live database. See its README. `supabase/verify/verify_rebuild.sh` proves it |
| `docs/database-explained.md` | The schema in plain language. **Read this first.** |
| `docs/prd-billing-screen.md` | What the billing screen must do, with acceptance criteria |
| `docs/design-system-decision.md` | Colours, type, touch targets, and which of the 80 screen mockups survive |
| `docs/agent-architecture.md` | What the AI agent owns, what it must never touch, and why |
| `docs/developer-hiring-brief.md` | Hiring the reviewer — including questions a non-developer can score |
| `demo/sna-pos-demo.html` | A working billing demo. Open it in a browser; no build step. |
| `app/e2e-ui/` | 71 browser tests of the real app (real Chromium, real PostgREST, real database) (`npm run test:ui` in `app/`). Read its README |
| `app/e2e/` | 61 end-to-end tests of the money path against a throw-away database (`npm run test:e2e` in `app/`). Read its README |
| `STATUS.md` | Current state, decisions, blockers. Start here on any new day. |

## The three rules this design exists to enforce

**1. One restaurant can never see another's data.**
Every business table carries a `restaurant_id`, and Row Level Security enforces
it in the database rather than in application code — so a bug in the app still
cannot leak a tenant's data. All 42 live tables have it, generated in a loop so
none can be forgotten.

**2. Tax is configuration, not code.**
A tax group has a dated rate, and that rate has named components. India prints
CGST + SGST (or IGST across states); the UAE prints a single VAT line; Singapore
prints GST. Same tables, no code change. Adding a country is data entry.

**3. Money records are immutable.**
A completed bill cannot be edited, by anyone, including via direct database
access. It is voided or refunded, and a void requires a named person and a
reason. Item names and prices are copied onto the bill at the time of sale, so
changing a menu price tomorrow never alters last week's bills.

## Not in V1

Inventory, recipes, purchase orders, suppliers, loyalty, online-order
aggregators, table QR ordering, multi-outlet reporting and accounting sync are
all deliberately out of scope. They are real, and they are V2.

**Saudi Arabia is blocked**, not merely unbuilt: it legally requires a
government-certified e-invoice from the POS itself. The `countries` table records
this per country so the application can refuse to go live there. It must not be
promised to a customer.

## Applying the schema

The schema is currently live on the Supabase project **SNA POS** (`ap-south-1`,
Mumbai), applied as six migrations:

```
sna_pos_01_core
sna_pos_02_orders_payments
sna_pos_03_row_level_security
sna_pos_04_reference_seed
sna_pos_05_agent
sna_pos_06_move_citext_out_of_public
```

To build a fresh database from this repository, run the two files in order
against an empty Postgres 15+ or Supabase project:

```bash
psql "$DATABASE_URL" -f supabase/schema/01_schema.sql
psql "$DATABASE_URL" -f supabase/schema/02_agent.sql
```

Neither file deletes or modifies anything that already exists. Do not run them
against a database that has data in it.

## Security

- **No secrets in this repository, ever.** Keys live in Supabase and Vercel
  environment settings. See `.env.example`.
- **The service-role key bypasses Row Level Security entirely.** It must never
  appear in browser code, in this repository, or in the agent. This is the single
  most dangerous mistake available in this codebase, and it is what most
  tutorials teach.
- **Card numbers are never stored.** That is the payment provider's job.
- Customer phone numbers are personal data under India's DPDP Act 2023.

Supabase's security advisors currently report **0 warnings** on the live project.

## Before real customers

None of these are optional, and none can be done by an AI:

- [ ] A human developer reviews this code
- [ ] An independent penetration test of the live application
- [ ] A chartered accountant confirms the GST rates and registration fields
- [ ] Thermal printer testing on real hardware (58mm and 80mm)
- [ ] Payment gateway onboarding — needs a registered company, GST and KYC
- [ ] Privacy policy, including AI processing disclosure
- [ ] Trademark search on the name "SNA POS"

## Licence

Proprietary. © SNA.AI. All rights reserved.
