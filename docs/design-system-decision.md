# SNA POS — Design System Decision v1.0

**Owner:** UX/UI Designer · **Approved by:** Founder (pending) · **Date:** 23 Sep 2026
**Replaces:** the two competing themes in the RPOS screen pack

---

## Plain-language summary

The 80 screens you already have were drawn in **two different visual styles**. A
developer cannot build from two styles, so one had to win. **The purple/blue style
wins.** Six screens get redrawn in it, and the menu order from the red style is
kept because it was better. Nothing else changes, and none of your work is thrown
away.

---

## 1. What the audit found

| | Family A | Family B |
|---|---|---|
| Screens | 001–074 (74 screens) | 075–080 (6 screens) |
| Theme | Dark navy with purple/blue accent | Dark with red accent |
| Logo | Gradient "R" mark | Flat red wordmark |
| First menu item | Dashboard | POS |
| Menu labels | POS Billing, Kitchen (KDS), Table Management | POS, KDS, Tables, Menu / Items |
| Content strength | Broad coverage, admin-heavy | The hard screens: checkout, refund, shift close, offline states |

## 2. The decision

**Visual style: Family A (purple/blue) becomes the SNA POS design system.**

Three reasons, in order of weight:

1. **Volume.** Keeping Family A means redrawing 6 screens. Keeping Family B means
   redrawing 74. That alone decides it.
2. **Differentiation.** The competitor site that started this project is built on
   red and white. A red POS invites the comparison we are trying to avoid, and the
   Legal role would rather we did not sit that close to an existing brand.
3. **Brand fit.** SNA POS sits under SNA.AI alongside SNA BuildOS. A shared
   blue/violet family lets the two products look like one company.

**Navigation: Family B's order is kept.** Family B put **POS first**, which is
correct — the cashier opens the billing screen, not a dashboard. Family A's
"Dashboard first" order is an admin habit, not a cashier one.

**Content: Family B's screens are kept in full.** Screens 075–080 cover checkout,
payment success, tax invoice, refund, end-of-shift cash close and the offline /
sync / error states. That is the most valuable thinking in the whole pack. It is
re-skinned, not rewritten.

## 3. What happens to each screen

| Screens | Action | Effort |
|---|---|---|
| 001–074 | **Keep.** Re-label the menu to the agreed order, swap RPOS → SNA POS | ~1 day |
| 075–080 | **Re-skin** into the purple/blue system, keep every element and state | ~2 days |
| Screen 075 | **Fix bug** — the Quick Amount row shows ₹1,000 twice | 5 minutes |
| All | **Rename** every RPOS logo, title and footer to SNA POS | included above |
| — | **New: tablet billing layout** (does not exist yet) | ~3 days |
| — | **New: light mode for the billing screen** | ~1 day |

## 4. The two gaps that must be filled before any code

### 4.1 There is no tablet layout
Every screen in the pack is 1536×1024 desktop. Real cashiers bill on a 10-inch
tablet held in portrait or a compact touch terminal. The billing screen in
particular has to be redrawn for touch. This is not a nice-to-have: it is the
screen the product is judged on.

### 4.2 Dark mode alone is not enough
Dark looks good in a dim dining room. It is close to unreadable at a takeaway
counter in daylight or near a window. The billing screen needs a light theme and
a manual toggle — never automatic, because a cashier should not have the screen
change under them mid-order.

## 5. The SNA POS design system

### Colour
| Token | Value | Used for |
|---|---|---|
| `--brand-primary` | `#6D4AFF` | Primary buttons, active menu item |
| `--brand-secondary` | `#3B6EF5` | Links, secondary accents |
| `--surface-base` | `#0B1020` | App background (dark) |
| `--surface-raised` | `#141A2E` | Cards, panels |
| `--surface-base-light` | `#F7F8FC` | App background (light) |
| `--success` | `#16A34A` | Paid, synced, ready |
| `--warning` | `#D97706` | Offline, pending sync, low stock |
| `--danger` | `#DC2626` | Void, delete, sync failed |
| `--text-primary` | `#F1F3F9` dark / `#0F172A` light | Body text |

Every colour pair must reach WCAG AA contrast (4.5:1 for text). The QA Engineer
checks this, not the designer.

### Type
- Family: **Inter** — free, screen-legible, carries Tamil and Arabic companions
- Bill total: 32px bold — the cashier must read it without leaning in
- Item rows: 16px minimum. Never below 14px anywhere in the product

### Touch
- Minimum tap target **48×48px** (the earlier note said 44; a cashier working fast
  with wet or greasy hands needs more)
- Minimum 8px gap between any two tappable things
- **Void, Delete and Refund are never adjacent to Confirm.** Separate them by at
  least 64px or put them behind a confirm step

### Components (map to Tailwind + shadcn/ui)
Button, Input, Select, Card, Table, Badge, Dialog, Sheet, Toast, Tabs,
NumberPad, ItemTile, CartRow, StatusPill, OfflineBanner.

Every screen must specify its **empty**, **loading**, **error** and **offline**
state. A screen spec without all four is not finished and the Frontend Engineer
should send it back.

### Localisation from day one
- Currency, date and number formats come from the branch's country — never
  hardcoded to ₹ or DD/MM/YYYY
- Every label goes through a translation file. Tamil first, then Hindi, then Arabic
- Arabic needs right-to-left layout. Designing for it now is cheap; retrofitting is
  not

## 6. Naming rule

The product is always written **SNA POS** in full — never "POS" alone, never
"RPOS", never "SNAPOS". This matches the rule already agreed for SNA BuildOS.

## 7. Hand-offs

- → **Frontend Engineer:** build the token set and component library from §5 first,
  before any screen
- → **Product Manager:** the tablet billing screen needs its PRD before it can be
  designed
- → **QA Engineer:** contrast and tap-target checks go in the release checklist
- → **Legal & Compliance Lead:** trademark search on "SNA POS" before launch
