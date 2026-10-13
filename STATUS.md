# SNA POS Status

_Shared memory for the SNA POS product. Read at the start of every chat; updated by
the Chief of Staff at the end of every work session. Companion to
`claude/BuildOS-Status.md`._

**Last updated:** 23 Sep 2026 (fourth session)

## Current goal and phase

**Phase 3 — Build.** The Founder asked Claude to develop the product. Stage 1
(database foundation) is **live on Supabase**. Stages 2–6 to follow.

_Earlier: Phase 2 — Demo build._ SNA BuildOS is **paused**; the SNA.AI website carries it
as "In development". All effort is on SNA POS. Target: a working billing demo in the
Founder's hands by **30 September 2026** to show a waiting restaurant owner.

_Earlier: Phase 1 — Specification._ Founder's earlier R&D (80 screen mockups + 2 spec
documents, built as "RPOS") has been audited and the three blocking problems fixed.
Product renamed to **SNA POS**. Customer interviews dropped at the Founder's
direction — he is the domain authority. The **SNA POS Agent** is now part of the
product. The billing demo is built; production code has not started.

## What SNA POS is

A point-of-sale product for small restaurants, under the SNA.AI company, designed
to be sold in more than one country. Reference point for the market was a
competitor's restaurant POS site — **not to be copied in design, copy or branding.**

## Build stages

| Stage | What | State |
|---|---|---|
| 1 | Supabase project, schema, RLS, agent tables | **Done — live** |
| 2 | Auth, users, roles, restaurant setup | Next |
| 3 | Menu management (categories, items, tax groups) | Not started |
| 4 | Billing → payment → receipt, online | Not started |
| 5 | Offline layer — the hard one | Not started |
| 6 | Day close, reports, then the agent | Not started |

## This week's top 3 (to 30 September)

1. **Founder** — show the billing demo to the waiting restaurant owner and bring
   back what they say. That reaction is the most valuable input available.
2. **Founder** — answer the four questions in the billing PRD §8 and the three in
   `agent-architecture.md`.
3. **Founder** — find a developer to review the schema. This is the standing top
   blocker and nothing real ships without it.

## Done recently

- 23 Sep 2026: Audited the Founder's existing R&D pack. Findings: 80 screen
  mockups (good), 2 spec documents (thin), **no code, no SQL, no repository**.
  Progress assessed at ~30–40% of design/spec, 0% of build.
- 23 Sep 2026: **Database rebuilt** — `sna-pos/sna_pos_schema_v2.sql`, 37 tables.
  Run on a real PostgreSQL 16 instance and tested: tenant isolation proved with two
  restaurants (0 rows leaked, cross-tenant insert refused), multi-country tax proved
  with India + UAE, four money-protection rules proved.
- 23 Sep 2026: **Design system resolved** — two competing themes reduced to one.
- 23 Sep 2026: **Billing screen PRD written**, replacing the bullet-list UX spec.
- 23 Sep 2026: Name applied throughout as **SNA POS**.
- 13 Oct 2026: **Live database captured in git** — `supabase/schema/03_live_baseline.sql`
  (100 tables, 331 functions, RLS, policies, grants). Loaded into a fresh Postgres
  and the object counts match live. The numbered migrations in `supabase/migrations/`
  are still incomplete (46 of ~111 files); this file is the source of truth until
  they are backfilled. It holds no data and no secrets: `app.secrets.pin_pepper` and
  the vault secrets `push_secret` / `push_url` must be recreated by hand on a rebuild.
- 23 Sep 2026: **SNA POS Agent designed** — `sna-pos/agent-architecture.md`. Four
  agent jobs defined, with a hard line between what deterministic code owns (money)
  and what the agent owns (language, suggestions, analysis).
- 23 Sep 2026: **Agent tables added and tested** — `sna_pos_migration_002_agent.sql`.
  Five new tables, a read-only `sna_pos_agent` database role, and its own RLS
  policies. Tested on real PostgreSQL: the agent can read its own restaurant's
  sales, but attempts to delete bills, change a bill total, self-approve its own
  proposal, or read another restaurant's data were all refused.
- 23 Sep 2026: **Working billing demo built and published** — tablet layout,
  Chettinad menu with Tamil names, live GST in paise, discount with approver,
  cash payment with change, 80mm thermal receipt, day close, offline mode with
  sync, and an owner's-analyst preview answering from real demo data. Two bugs
  found and fixed by testing it: a tax-rate label that printed the wrong
  percentage on a cart mixing tax groups, and emoji payment icons replaced with
  inline SVG.
- 23 Sep 2026: Two bugs found and fixed during testing of migration 002 — an invalid
  trigger block, and agent read policies missing entirely (the agent could read
  nothing at all, including its own data).

## Decisions made

- 23 Sep 2026 (Founder): **Claude builds SNA POS.** Claude writes the code; the
  human developer's role changes from "review this schema" to "review what the AI
  built". The review is *more* necessary, not less — an AI cannot independently
  review its own work.
- 23 Sep 2026 (Founder): **Seoul "BuildOS" Supabase project paused** to free a free-
  tier slot. Reversible; data retained; nothing deleted.

### Live infrastructure
- **Supabase project: "SNA POS"** — ref `lrtoktmfspnypkgrvnzg`, region ap-south-1
  (Mumbai), org `snaomkproject`.
- 6 migrations applied: `sna_pos_01_core`, `02_orders_payments`,
  `03_row_level_security`, `04_reference_seed`, `05_agent`,
  `06_move_citext_out_of_public`.
- **42 tables · 42 with RLS · 86 policies · 23 triggers · 20 permissions ·
  6 countries.**
- **Supabase security advisors: 0 warnings.** (For contrast, the BuildOS projects
  show 27.)
- No restaurant, user or menu data exists yet. The database is empty of business data.

- 23 Sep 2026 (Founder): **SNA BuildOS paused.** Website shows it as "In
  development". Full focus on SNA POS.
- 23 Sep 2026 (Founder): **Target 30 September** = a working demo to show a
  restaurant owner who is waiting. Not a live product — see the risk below.

- 23 Sep 2026: Product name is **SNA POS**, always written in full — never "POS"
  alone, never "RPOS". Same rule as SNA BuildOS.
- 23 Sep 2026: Design system = the purple/blue theme (screens 001–074). Reasons:
  74 screens vs 6; the red theme sits too close to the competitor's branding; blue
  matches SNA BuildOS so the two products look like one company.
- 23 Sep 2026: Navigation order taken from screens 075–080 — **POS first**, not
  Dashboard first. The cashier is the primary user.
- 23 Sep 2026: V1 scope = menu, order, KOT, bill, payment, day close, offline.
  Inventory, recipes, purchase orders, aggregators, loyalty and multi-outlet all
  go to V2.
- 23 Sep 2026: Tax is a configurable rule engine, not Indian GST columns. Adding a
  country is data entry, not a rebuild.
- 23 Sep 2026: Financial records are immutable. Bills are voided or refunded, never
  edited or deleted.
- 23 Sep 2026: Passwords are never stored in our tables; Supabase Auth holds them.
  Card numbers are never stored anywhere.
- 23 Sep 2026 (Founder): **No customer interviews.** The Founder has worked on POS
  and is the domain authority for SNA POS.
- 23 Sep 2026 (Founder): **An AI agent ships as part of SNA POS**, handling product
  intelligence and future AI features.
- 23 Sep 2026 (System Architect, needs Founder confirmation): **The agent never
  calculates money and billing never waits for the agent.** Totals, tax, discounts,
  payments and rounding stay in deterministic code. The agent reads, explains,
  summarises and proposes. See `agent-architecture.md`.
- 23 Sep 2026 (Security Engineer): **The agent never uses the service-role key.** It
  runs read-only under the signed-in user's token, so tenant isolation applies to it
  exactly as it applies to a person.

## Open decisions for the Founder

- **Priority:** SNA POS vs SNA BuildOS vs both. With interviews dropped there is no
  cheap validation step left, so this is now a straight choice. One builder is
  waiting on SNA BuildOS.
- **Which agent job ships first?** Recommendation: the owner's analyst — read-only,
  no money risk, and the feature that sells the product.
- **Confirm the money/agent split** in `agent-architecture.md` §"What I need from
  the Founder", question 2.
- **Does the agent need Tamil from day one?** It changes the model choice and the
  testing effort.
- **First market:** India only, with the design ready for others? Recommendation: yes.
- **Business type:** restaurants only, or retail and bakery too? Recommendation:
  restaurants only for V1.
- The three PRD questions in §8 (PIN login, print-before-payment, market).

## Blockers and risks

- **30 September is a demo date, not a launch date.** A restaurant cannot run its
  business on SNA POS by then. Four things make it impossible regardless of build
  speed: no developer has reviewed the code; payment gateway onboarding needs a
  registered company, GST, a bank account and KYC approval (weeks, waiting on third
  parties); no thermal printer exists to test against; and offline sync is the
  hardest part of the product. Realistic business-ready date: **around February
  2027**.
- **The pilot builder was left waiting** when SNA BuildOS was paused. If that
  relationship matters, someone should tell them the timeline has moved.

- **Direction rests on one person.** Interviews were dropped by Founder decision, so
  there is no outside check on the product direction until the pilot. Cheapest
  insurance: show the first working build to three real restaurant owners before the
  pilot starts. Founder's call.
- **The agent is the biggest new security risk.** If it is ever built with the
  service-role key instead of the user's token, every tenant-isolation protection in
  the database is bypassed at once. A written prompt-injection threat model is
  required before any agent code.
- **Agent running costs are unmeasured.** Pricing cannot be finalised until cost per
  question is measured on real usage, not estimated.
- **No human developer.** The schema is tested but not reviewed. Nothing should
  reach a real database without a human review.
- **Saudi Arabia is blocked.** It legally requires a government-certified e-invoice
  from the POS. Until that certification exists, SNA POS cannot be sold there and
  must not be promised.
- **Two products, one very small team.** This is the largest risk to both.
- **Hardware support burden.** Thermal printers on three common models must be
  tested before the first customer. POS support is urgent by nature ("printer dead
  at 8pm Friday") and needs a support plan before launch, not after.
- **Trademark.** "SNA POS" needs an IP India search by the same lawyer handling
  "SNA BuildOS". POS product names are crowded.
- **Crowded market.** Several well-funded restaurant POS players already exist in
  India. The Researcher's competitor matrix must find a real gap before building.

## Next steps (owner → task)

- **Researcher** → cited competitor matrix only (still needed for pricing and
  positioning; no interviews).
- **Founder** → answer PRD §8 and the three agent questions; decide priority; add
  "SNA POS" to the lawyer's trademark brief.
- **UX/UI Designer** → tablet layout and light mode: **done in the demo**. Still
  open: re-skin screens 075–080, fix the duplicate ₹1,000 button on screen 075.
- **System Architect + Security Engineer** → offline sync design document.
- **Backend Engineer** → hold. Nothing goes to a live database until a human
  developer reviews the schema and migration 002.
- **Security Engineer** → prompt-injection threat model for the SNA POS Agent,
  before any agent code is written.
- **Finance Lead** → cost estimate: printer samples, test tablet, payment gateway
  fees, developer review time.
- **Legal & Compliance Lead** → trademark search; confirm the competitor's site was
  used only as a market reference and nothing was copied; add an AI-processing
  disclosure to the privacy policy before the agent goes live.
