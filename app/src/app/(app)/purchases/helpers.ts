/** Types and small sums shared by the Purchases screens (server and client). No database calls here. */

export type Fail = { ok: false; error: string };

export type SupplierRow = {
  id: string;
  name: string;
  contact_person: string | null;
  phone: string | null;
  email: string | null;
  tax_no: string | null;
  address: string | null;
  payment_days: number;
  notes: string | null;
  is_active: boolean;
  blocked: boolean;
  blocked_reason: string | null;
};
export type SupplierPick = { id: string; name: string };

export type Ingredient = { id: string; name: string; unit: string; cost: number; /** Optional buying unit, e.g. kg for an ingredient kept in g. */ buyUnit?: string; buyFactor?: number };
export type StockedIngredient = Ingredient & { stock: number; reorder: number };
/** Name and unit of every ingredient ever used, including ones switched off since. */
export type IngredientNames = Record<string, { name: string; unit: string }>;

/** One line while it is being typed. */
export type LineDraft = { ingredient_id: string; qty: string; cost: string; /** Typed in the buying unit instead of the stock unit. */ buy?: boolean; /** Tax % on this line, e.g. "5". Blank means none. */ taxRate?: string };
/** One line as the database wants it. */
export type CleanLine = { ingredient_id: string; qty: number; unit_cost: number; unit?: "purchase"; tax_rate?: number };
export type OrderLine = { ingredient_id: string; qty: number; unit_cost: number; received_qty: number };

/** A purchase order with its lines. `date` is the day it was written (YYYY-MM-DD, restaurant time). */
export type OrderRow = {
  id: string;
  number: string;
  supplier_id: string;
  status: string;
  expected_on: string | null;
  notes: string | null;
  total: number;
  date: string;
  lines: OrderLine[];
};

/** Plain words for where an order stands. */
export const ORDER_STATUS: Record<string, { label: string; bg: string; fg: string }> = {
  draft: { label: "Draft", bg: "var(--color-ground)", fg: "var(--color-ink-2)" },
  ordered: { label: "Sent", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  part_received: { label: "Part received", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  received: { label: "Received", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  cancelled: { label: "Cancelled", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
};

/** One delivery that was received (a goods receipt). */
export type ReceiptRow = {
  id: string;
  number: string;
  supplier_id: string;
  bill_no: string | null;
  received_on: string;
  total: number;
  paid: number;
  owed: number;
  refund: number;
  cancelled: boolean;
  cancel_reason: string | null;
  /** What has gone back to the supplier already (money). */
  returned: number;
  /** What can still go back, per ingredient. */
  returnable: { ingredient_id: string; name: string; unit: string; remaining: number; unit_cost: number }[];
};

/** What the pay form needs to know about the receipt being paid. */
export type PayTarget = { id: string; number: string; supplier: string; owed: number };

/** One payment made to a supplier against a receipt. `undone` is true once it has been undone (with the reason given). */
export type PaymentRow = {
  id: string;
  receipt_id: string;
  paid_on: string;
  method: string;
  amount: number;
  reference: string | null;
  from_till: boolean;
  undone: boolean;
  undo_reason: string | null;
};

/** purchase_report(): what was bought in a period and everything still owed. */
export type OwedRow = {
  id: string;
  number: string;
  supplier_id: string;
  supplier: string;
  bill_no: string | null;
  received_on: string;
  due_on: string | null;
  total: number;
  paid: number;
  owed: number;
  overdue: boolean;
};
export type PurchaseReport = {
  totals: { receipts: number; bought: number; owed: number; overdue: number; refund_due: number };
  by_supplier: { supplier_id: string; supplier: string; receipts: number; total: number; paid: number; owed: number; refund_due: number }[];
  owed: OwedRow[];
  by_ingredient: { ingredient: string; unit: string; category: string | null; qty: number; amount: number; avg_cost: number | null }[];
};
export const EMPTY_REPORT: PurchaseReport = { totals: { receipts: 0, bought: 0, owed: 0, overdue: 0, refund_due: 0 }, by_supplier: [], owed: [], by_ingredient: [] };

export const BLANK_LINE: LineDraft = { ingredient_id: "", qty: "", cost: "" };

const PAY_METHODS = [
  ["cash", "Cash"],
  ["bank", "Bank transfer"],
  ["upi", "UPI"],
  ["cheque", "Cheque"],
  ["card", "Card"],
  ["other", "Other"],
] as const;
export type PayMethod = (typeof PAY_METHODS)[number][0];

/** Ways to pay a supplier. UPI is offered in India only. */
export function payMethods(country: string): readonly (readonly [PayMethod, string])[] {
  return PAY_METHODS.filter(([k]) => k !== "upi" || country === "IN");
}
export function isPayMethod(x: unknown): x is PayMethod {
  return PAY_METHODS.some(([k]) => k === x);
}
/** "bank" → "Bank transfer" */
export function payMethodLabel(x: string): string {
  return PAY_METHODS.find(([k]) => k === x)?.[1] ?? x;
}

function plain(n: number): string {
  const s = String(n);
  return /e/i.test(s) ? n.toFixed(10) : s;
}

/**
 * A typed amount as a whole number of 10^-dp units, rounded half up — the same
 * way the database rounds, so the total on screen is the total that gets saved.
 * Null when it is not a plain number of zero or more.
 */
export function scaled(input: string | number, dp: number): bigint | null {
  const s = typeof input === "number" ? (Number.isFinite(input) ? plain(input) : "") : input.trim();
  const m = /^(\d*)(?:\.(\d*))?$/.exec(s);
  if (!m) return null;
  const whole = m[1];
  const frac = m[2] ?? "";
  if ((whole === "" && frac === "") || whole.length > 15) return null;
  const digits = frac.padEnd(dp + 1, "0");
  const v = BigInt((whole || "0") + digits.slice(0, dp));
  return digits.charCodeAt(dp) >= 53 ? v + BigInt(1) : v;
}

/** Quantity × cost per unit, in hundredths of the currency (0 while either is not a number yet). */
export function lineCents(qty: string | number, cost: string | number): number {
  const q = scaled(qty, 3);
  const c = scaled(cost, 4);
  if (q === null || c === null) return 0;
  return Number((q * c + BigInt(50000)) / BigInt(100000));
}

/** Tax on one line in hundredths, the way the database rounds it (tax % of the rounded line amount). */
export function lineTaxCents(qty: string | number, cost: string | number, rate: string | number | undefined): number {
  const r = Number(String(rate ?? "").trim() === "" ? 0 : rate);
  if (!Number.isFinite(r) || r <= 0 || r > 100) return 0;
  return Math.round((lineCents(qty, cost) * r) / 100);
}

/** All the per-line tax on the typed lines, in hundredths. */
export function linesTaxCents(lines: LineDraft[]): number {
  return lines.reduce((s, l) => s + lineTaxCents(l.qty, l.cost, l.taxRate), 0);
}

/** A money amount in hundredths of the currency, or null when it is not a number. Blank counts as zero. */
export function amountCents(x: string | number): number | null {
  if (typeof x === "string" && x.trim() === "") return 0;
  const v = scaled(x, 2);
  return v === null ? null : Number(v);
}

/** Checks the typed lines and turns them into what the database expects. Empty rows are ignored. */
export function checkLines(lines: LineDraft[], names: IngredientNames): { ok: true; lines: CleanLine[] } | Fail {
  const out: CleanLine[] = [];
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (!l.ingredient_id && l.qty.trim() === "") continue;
    if (!l.ingredient_id) return { ok: false, error: `Choose the ingredient on line ${i + 1}.` };
    const name = names[l.ingredient_id]?.name ?? `line ${i + 1}`;
    const q = scaled(l.qty, 3);
    if (q === null || q <= BigInt(0)) return { ok: false, error: `Enter a quantity for ${name}.` };
    if (l.cost.trim() === "" || scaled(l.cost, 4) === null) return { ok: false, error: `Enter the cost per unit for ${name} (0 if it was free).` };
    if (out.some((x) => x.ingredient_id === l.ingredient_id)) return { ok: false, error: `${name} is on the list twice. Put it on one line.` };
    const tr = (l.taxRate ?? "").trim();
    const rate = tr === "" ? 0 : Number(tr);
    if (!Number.isFinite(rate) || rate < 0 || rate > 100) return { ok: false, error: `Tax % for ${name} must be between 0 and 100.` };
    out.push({ ingredient_id: l.ingredient_id, qty: Number(l.qty.trim()), unit_cost: Number(l.cost.trim()), ...(l.buy ? { unit: "purchase" as const } : {}), ...(rate > 0 ? { tax_rate: rate } : {}) });
  }
  if (out.length === 0) return { ok: false, error: "Add at least one ingredient." };
  return { ok: true, lines: out };
}

/** What is still to come on orders that are Sent or Part received, by ingredient. */
export function onOrderQty(orders: { status: string; lines: OrderLine[] }[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const o of orders) {
    if (o.status !== "ordered" && o.status !== "part_received") continue;
    for (const l of o.lines) out[l.ingredient_id] = (out[l.ingredient_id] ?? 0) + (l.qty - l.received_qty);
  }
  return out;
}

/**
 * A suggested quantity rounded up to something easy to order: a whole number
 * from 10 up, the next half between 1 and 10, and two decimals below 1 (so a
 * reorder level of 0.05 kg does not become 1 kg).
 */
function roundUpQty(x: number): number {
  if (x >= 10) return Math.ceil(x - 1e-9);
  if (x >= 1) return Math.ceil(x * 2 - 1e-9) / 2;
  return Math.ceil(x * 100 - 1e-9) / 100;
}

/**
 * A line for every ingredient at or below its reorder level. Suggested quantity:
 * enough to reach twice the reorder level, and never less than the reorder level,
 * less what is already on its way on open orders (`onOrder`, by ingredient).
 * Nothing is suggested for an ingredient that is already fully on order.
 */
export function lowStockLines(items: StockedIngredient[], onOrder: Record<string, number> = {}): LineDraft[] {
  const out: LineDraft[] = [];
  for (const i of items) {
    if (!(i.reorder > 0 && i.stock <= i.reorder)) continue;
    const want = Math.max(i.reorder * 2 - i.stock, i.reorder) - Math.max(0, onOrder[i.id] ?? 0);
    // Quantities are kept to three decimals: anything smaller is nothing.
    if (!(want >= 0.0005)) continue;
    out.push({ ingredient_id: i.id, qty: String(roundUpQty(want)), cost: String(i.cost) });
  }
  return out;
}

/** True when a cost per unit has more decimals than the currency shows (0.125 a gram, say). */
export function fineCost(x: number): boolean {
  return Math.abs(Math.round(x * 100) - x * 100) > 1e-6;
}

/** 2.500 → "2.5" */
export function qtyText(x: number | string): string {
  return (Math.round(Number(x) * 1000) / 1000).toString();
}

/** "2026-10-04" → "4 Oct 2026" */
export function dayLabel(ymd: string | null | undefined): string {
  if (!ymd) return "—";
  return new Date(ymd.slice(0, 10) + "T00:00:00Z").toLocaleDateString("en-IN", {
    timeZone: "UTC",
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

/** The calendar day (YYYY-MM-DD) of a moment, in the restaurant's timezone. */
export function ymdIn(iso: string, tz: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
}

/** The lines still to come on an order, ready for the Receive form. */
export function remainingLines(order: OrderRow): LineDraft[] {
  return order.lines
    .filter((l) => l.qty - l.received_qty > 0.0005)
    .map((l) => ({ ingredient_id: l.ingredient_id, qty: qtyText(l.qty - l.received_qty), cost: String(l.unit_cost) }));
}

/** The lines of an order as typed text, for editing a draft. */
export function orderDraftLines(order: OrderRow): LineDraft[] {
  return order.lines.map((l) => ({ ingredient_id: l.ingredient_id, qty: qtyText(l.qty), cost: String(l.unit_cost) }));
}

/** Total of the typed lines, in hundredths of the currency. */
export function linesCents(lines: LineDraft[]): number {
  return lines.reduce((s, l) => s + (l.ingredient_id ? lineCents(l.qty, l.cost) : 0), 0);
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function isUuid(x: unknown): x is string {
  return typeof x === "string" && UUID.test(x);
}

/**
 * A new reference for one request (a goods receipt, a supplier payment). The
 * same reference is sent on every retry of that request, so a second tap or a
 * retry never saves it twice.
 */
export function newRef(): string {
  const c: Crypto | undefined = globalThis.crypto;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  // Pages not served over https have no randomUUID: build the same kind of id by hand.
  const b = new Uint8Array(16);
  if (c && typeof c.getRandomValues === "function") c.getRandomValues(b);
  else for (let i = 0; i < 16; i++) b[i] = Math.floor(Math.random() * 256);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

/** A request reference together with exactly what was first sent under it. */
export type SentRef = { ref: string; sent: string };

/**
 * The reference to send with `payload`. The reference belongs to the content:
 * sending the very same thing again (a retry) reuses it, so it is saved once;
 * anything different gets a new one, so an edited form is never answered with
 * "already saved" while the server still holds the earlier version.
 */
export function refFor(last: SentRef | null, payload: unknown): SentRef {
  const sent = JSON.stringify(payload);
  return last && last.sent === sent ? last : { ref: newRef(), sent };
}
