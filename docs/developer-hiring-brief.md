# SNA POS — Developer Hiring Brief

**Owner:** Engineering Lead · **For:** Founder · **Date:** 23 Sep 2026
**Purpose:** hire the human developer who reviews the SNA POS database before
anything touches real data — the standing top blocker on this product.

---

## The strategy in one line

**Hire small first.** Pay one developer for a short, well-defined review. That review
is both the thing you need *and* a paid trial. If they do it well, you have found
your build partner. If they do it badly, you have lost a few thousand rupees instead
of three months.

Do not hire someone to "build SNA POS" as a first engagement. You cannot evaluate
that contract, and neither can they.

---

## Phase A — the paid review (hire this now)

**Deliverable:** a written review of `sna_pos_schema_v2.sql` and
`sna_pos_migration_002_agent.sql`, answering:

1. Does the tenant isolation actually hold? Is there any table, function or policy
   path where restaurant A could reach restaurant B's data?
2. Are the `SECURITY DEFINER` functions safe as written?
3. Will the money columns and the tax calculation hold up — precision, rounding,
   the frozen tax breakdown?
4. Is the offline design sound? Specifically: device-generated IDs, per-device bill
   numbering, and whether a bill sent twice can become two bills.
5. Is the read-only agent role genuinely read-only?
6. What would they change, and what would they have done differently?

**Size:** roughly 6–10 hours of work. It is a review, not a build.

**What to send them:** the two `.sql` files and `database-explained.md`. That is all
they need, and **those files contain no passwords, keys or customer data** — so
sending them costs you nothing.

**What NOT to send:** your Supabase login, the service-role key, any API key, or
access to a live project. Not to a candidate, not to a hire on day one. A developer
who asks for production access before doing any work is a red flag on its own.

## Phase B — the build (only if Phase A goes well)

Frontend and backend for V1 billing, working from the PRD and the design system
document. Discuss after the review, not before.

---

## What they need to know

**Required**
- PostgreSQL, properly — not just "I use a database". They must be fluent in Row
  Level Security, policies, `SECURITY DEFINER` and `search_path`.
- Supabase: Auth, RLS, Edge Functions, migrations.
- TypeScript and Next.js (App Router).

**Strongly preferred**
- Offline-first or sync-heavy applications. This is the rarest skill on the list and
  the one that will decide whether SNA POS works in a real restaurant.
- Anything billing, invoicing, payments or accounting — someone who already
  understands why a financial record must be immutable.
- Thermal printer / ESC-POS experience. Rare, valuable, worth asking about.

**Not required**
- Restaurant industry experience. You bring that.
- AI or LLM experience. The agent is a separate, later track.

---

## What to pay

Published 2026 rates for Indian developers, for reference:

| Level | Hourly (USD) | Roughly (INR) |
|---|---|---|
| Junior backend (2–3 yrs) | $15–22 | ₹1,300–1,900 |
| Mid-level backend (3–6 yrs) | $22–35 | ₹1,900–3,100 |
| Senior backend (6+ yrs) | $35–55 | ₹3,100–4,800 |
| Senior full-stack | $38–58 | ₹3,300–5,100 |

Indian domestic freelance web developer rates are quoted separately at ₹800–1,500/hr
for beginners, ₹1,500–3,000 for intermediate and ₹3,000–4,000+ for experienced.

**My recommendation for Phase A:** pay for a **senior**, because a junior reviewing a
security design tells you nothing — they will say it looks fine. Budget roughly
**₹25,000–45,000** for the review (INR conversion at ~₹88/USD; treat every figure
here as a starting point, not a quote).

That is the single highest-value spend on this product right now. It is cheaper than
one data-leak incident by several orders of magnitude.

---

## How to judge a candidate without reading code

You cannot assess their code. You can assess their **answers** — and for this
particular job, the answers are more revealing than a portfolio. Ask these six, in
this order.

### 1. "Every table in this schema has a `restaurant_id` and Row Level Security switched on. Why does that matter more than checking permissions in the application?"
- **Good:** because the database enforces it even when the app has a bug. Layers. An
  attacker who gets past the app still gets nothing.
- **Bad:** "they're much the same", or they cannot explain RLS without looking it up.
- *Why it works:* this is the single most important property of the product. Anyone
  who shrugs at it will build the leak.

### 2. "The POS must keep billing when the internet is down. Two tablets are billing offline at the same counter. How do you stop their bill numbers colliding?"
- **Good:** give each device its own prefix and its own counter; or generate IDs on
  the device. They should reach this quickly.
- **Bad:** "the server assigns the number" — that is exactly what cannot happen
  offline, and it means they have not thought about offline at all.

### 3. "A tablet comes back online and sends the same offline bill twice. How do you make sure it doesn't become two bills in the reports?"
- **Good:** the record already carries its own ID from the device, so the second send
  updates the same row. Words to listen for: *idempotent*, *upsert*, *client-generated key*.
- **Bad:** "check if it already exists first" with no answer to *check on what*.

### 4. "We want an AI agent that can read a restaurant's sales. A tutorial says to connect it with the Supabase service-role key. What do you think?"
- **Good:** immediate alarm. The service-role key bypasses RLS, so one bad query or
  one prompt injection leaks every restaurant's data. It should run under the user's
  own token.
- **Bad:** "that's fine, it's server-side."
- *Why it works:* this is the specific mistake that would undo everything, and it is
  what most tutorials teach. It separates people who follow tutorials from people who
  think.

### 5. "Why is money stored as `numeric` and not a normal decimal number?"
- **Good:** floating point cannot represent decimal amounts exactly; over thousands
  of bills you get rounding errors in the accounts.
- **Bad:** "it doesn't really matter."

### 6. "You've read the schema. What would you change?"
- **Good:** anything specific. A named table, a missing index, a constraint they
  would add, a disagreement with a decision.
- **Bad:** "it looks good to me." That means they did not read it.
- *Why it works:* this is the most useful question on the list. It tests whether they
  did the work, and it tells you whether they will push back on you later — which you
  want, because you cannot check their work yourself.

### Red flags
- Asks for production or Supabase access before doing any work.
- Quotes a price before asking a single question about scope.
- Agrees with everything. You need someone who will tell you no.
- Promises to build the whole product in an implausibly short time. You have already
  seen how that arithmetic goes.
- Will not sign an IP assignment.

---

## Before they start

**Get the IP assignment in writing.** SNA.AI must own everything they produce. This is
the same clause the Legal & Compliance Lead is already drafting for SNA BuildOS — use
it here too. Without it, the code they write is arguably theirs, and that becomes a
serious problem the day the product has value.

---

## The job post — copy and paste this

> **PostgreSQL / Supabase developer — paid schema review (6–10 hours, remote)**
>
> We are building SNA POS, a point-of-sale product for small restaurants, on
> PostgreSQL and Supabase. The database schema is written and tested. Before it goes
> anywhere near real data, we want an experienced developer to review it properly.
>
> **The work:** review a 37-table Supabase schema plus one migration. We want your
> written assessment of: multi-tenant isolation via Row Level Security, the safety of
> our `SECURITY DEFINER` functions, our money and tax handling, our offline-first sync
> design (device-generated IDs and per-device bill numbering), and a read-only
> database role intended for an AI agent. Tell us what is wrong and what you would
> change.
>
> **You should have:** solid PostgreSQL, including RLS and policy design; real
> Supabase experience (Auth, migrations, Edge Functions); TypeScript and Next.js.
> Experience with offline-first or sync-heavy apps, or with billing/invoicing systems,
> is a strong plus.
>
> **This is a paid trial.** If the review goes well there is ongoing work building the
> V1 product.
>
> **Terms:** fixed fee, agreed upfront. We will send you the SQL files and a plain-
> language design document — no credentials, no production access. You will be asked
> to sign an IP assignment before starting.
>
> Tell us briefly about a multi-tenant or offline-capable system you have built, and
> what you would charge for the review.

**Where to post:** Upwork and Contra for international reach; Wellfound and
Instahyre for India; LinkedIn with the post above; and — often best — ask in Supabase
and Indian developer communities, where people who genuinely know RLS actually are.

---

## Hand-offs

→ **Legal & Compliance Lead:** IP assignment draft, reusable for this hire
→ **Finance Lead:** budget line of ₹25,000–45,000 for the review
→ **Security Engineer:** brief the chosen developer on the threat model before Phase B

**Sources for the rate figures:**
- [Freelancer Charges in India 2026: Rate Card, USD Rates & Take-Home — xFlow](https://www.xflowpay.com/blog/freelancer-charges)
- [Software Development Rates in India 2026: Real Rate Card by Role, Seniority, and Stack — Acquaint Softtech](https://acquaintsoft.com/blog/software-development-rates-india)
