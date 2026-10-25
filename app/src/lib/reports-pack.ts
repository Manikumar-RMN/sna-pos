/**
 * Pure helpers for the "More reports" page (popular / slow items, waiter-wise
 * sales, discount summary, cancel and void audit). No database access here, so
 * every rule can be unit-tested.
 */
import { addDays, isYmd } from "./format";

const r2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;
const num = (v: unknown) => {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};

/** Same range presets as the main Reports page; `today` is the business day. */
export function resolveRange(
  today: string,
  sp: { range?: string; from?: string; to?: string },
): { from: string; to: string; range: string } {
  let from = today;
  let to = today;
  let range = sp.range ?? "today";
  if (isYmd(sp.from) && isYmd(sp.to)) {
    from = sp.from <= sp.to ? sp.from : sp.to;
    to = sp.from <= sp.to ? sp.to : sp.from;
    range = "custom";
  } else if (range === "yesterday") {
    from = to = addDays(today, -1);
  } else if (range === "7d") {
    from = addDays(today, -6);
  } else if (range === "month") {
    from = today.slice(0, 8) + "01";
  } else if (range === "lastmonth") {
    to = addDays(today.slice(0, 8) + "01", -1);
    from = to.slice(0, 8) + "01";
  } else {
    range = "today";
  }
  return { from, to, range };
}

// ---------- items ----------

export type ItemLine = { product_id: string | null; product_name: string; quantity: unknown; line_subtotal: unknown };
export type ItemSale = { key: string; name: string; qty: number; amount: number };

/** Units and amount per item (grouped by menu item, falling back to the printed name). */
export function aggregateItems(lines: ItemLine[]): ItemSale[] {
  const map = new Map<string, ItemSale>();
  for (const l of lines) {
    const key = l.product_id ?? `name:${l.product_name}`;
    const cur = map.get(key) ?? { key, name: l.product_name, qty: 0, amount: 0 };
    cur.qty += num(l.quantity);
    cur.amount += num(l.line_subtotal);
    map.set(key, cur);
  }
  return [...map.values()]
    .map((x) => ({ ...x, qty: r2(x.qty), amount: r2(x.amount) }))
    .sort((a, b) => b.qty - a.qty || b.amount - a.amount || a.name.localeCompare(b.name));
}

/**
 * Slow items = active menu items sold the least. `dead` are active items with no
 * sale at all in the range; `slow` are the lowest sellers among those that sold.
 * Items that sold nothing are never in `slow`, and sold items are never in `dead`.
 */
export function splitPopularSlow(
  sold: ItemSale[],
  activeItems: { id: string; name: string }[],
  opts: { top?: number; slow?: number } = {},
): { popular: ItemSale[]; slow: ItemSale[]; dead: { id: string; name: string }[] } {
  const top = opts.top ?? 100;
  const slowN = opts.slow ?? 20;
  const soldKeys = new Set(sold.map((s) => s.key));
  const activeIds = new Set(activeItems.map((a) => a.id));
  const dead = activeItems
    .filter((a) => !soldKeys.has(a.id))
    .sort((a, b) => a.name.localeCompare(b.name));
  // Only items still on the menu can be "slow"; a retired item that sold earlier is not a problem to fix.
  const slow = [...sold]
    .filter((s) => activeIds.has(s.key))
    .sort((a, b) => a.qty - b.qty || a.amount - b.amount || a.name.localeCompare(b.name))
    .slice(0, slowN);
  return { popular: sold.slice(0, top), slow, dead };
}

// ---------- waiters ----------

export type OrderRow = {
  business_date: string | null;
  cashier_id: string | null;
  waiter_id: string | null;
  covers: unknown;
  grand_total: unknown;
  subtotal: unknown;
  discount_total: unknown;
};
export type WaiterRow = { user_id: string; bills: number; covers: number; total: number; average: number };

/** Sales per waiter, using the cashier when no waiter was recorded. Sorted by sales. */
export function aggregateWaiters(orders: OrderRow[]): WaiterRow[] {
  const map = new Map<string, WaiterRow>();
  for (const o of orders) {
    const id = o.waiter_id ?? o.cashier_id;
    if (!id) continue;
    const cur = map.get(id) ?? { user_id: id, bills: 0, covers: 0, total: 0, average: 0 };
    cur.bills += 1;
    cur.covers += Math.max(0, Math.trunc(num(o.covers)));
    cur.total += num(o.grand_total);
    map.set(id, cur);
  }
  return [...map.values()]
    .map((w) => ({ ...w, total: r2(w.total), average: w.bills ? r2(w.total / w.bills) : 0 }))
    .sort((a, b) => b.total - a.total || a.user_id.localeCompare(b.user_id));
}

// ---------- discounts ----------

export type DiscountGroup = { key: string; bills: number; total: number; maxPercent: number };

/** Percent of the pre-discount bill value (subtotal) that was given away. */
export function discountPercent(subtotal: unknown, discount: unknown): number {
  const s = num(subtotal);
  const d = num(discount);
  if (s <= 0 || d <= 0) return 0;
  return r2(Math.min(100, (d / s) * 100));
}

function groupDiscounts(orders: OrderRow[], keyOf: (o: OrderRow) => string | null): DiscountGroup[] {
  const map = new Map<string, DiscountGroup>();
  for (const o of orders) {
    const d = num(o.discount_total);
    if (d <= 0) continue;
    const key = keyOf(o);
    if (!key) continue;
    const cur = map.get(key) ?? { key, bills: 0, total: 0, maxPercent: 0 };
    cur.bills += 1;
    cur.total += d;
    cur.maxPercent = Math.max(cur.maxPercent, discountPercent(o.subtotal, d));
    map.set(key, cur);
  }
  return [...map.values()].map((g) => ({ ...g, total: r2(g.total) }));
}

/** Discounted bills per cashier (the person who billed), biggest total first. */
export function discountsByUser(orders: OrderRow[]): DiscountGroup[] {
  return groupDiscounts(orders, (o) => o.cashier_id).sort((a, b) => b.total - a.total || a.key.localeCompare(b.key));
}

/** Discounted bills per business day, oldest first. */
export function discountsByDay(orders: OrderRow[]): DiscountGroup[] {
  return groupDiscounts(orders, (o) => o.business_date).sort((a, b) => a.key.localeCompare(b.key));
}

// ---------- audit ----------

/** Audit actions the app really writes (checked against the migrations), in plain words. */
export const AUDIT_ACTION_LABEL: Record<string, string> = {
  "order.void": "Bill voided",
  "order.cancel_item": "Item cancelled",
  "kot.cancel": "Kitchen ticket cancelled",
  "order.refund": "Refund",
  "credit_note.issue": "Credit note",
  "order.adjust": "Discount / bill adjusted",
  "order.complimentary": "Complimentary / staff meal",
  "approval.granted": "Manager PIN approval",
};
export const AUDIT_ACTIONS = Object.keys(AUDIT_ACTION_LABEL);

function rec(v: unknown): Record<string, unknown> {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}
const str = (v: unknown) => (typeof v === "string" ? v : typeof v === "number" ? String(v) : "");

export type AuditDetail = { bill: string; detail: string; reason: string; amount: number | null };

/** Reads the bill, what happened, the reason and the money out of an audit row's old/new value. */
export function auditDetail(action: string, newValue: unknown, oldValue: unknown): AuditDetail {
  const n = rec(newValue);
  const o = rec(oldValue);
  const reason = str(n.reason);
  const bill = str(n.bill_number);
  switch (action) {
    case "order.void":
      return { bill, detail: "Whole bill voided", reason, amount: o.grand_total == null ? null : num(o.grand_total) };
    case "order.cancel_item":
      return { bill, detail: `${str(n.qty) || "1"} × ${str(n.item)}`.trim(), reason, amount: null };
    case "kot.cancel":
      return { bill, detail: `Ticket ${str(n.ticket)}, ${str(n.items) || "0"} item(s)`, reason, amount: null };
    case "order.refund":
      return { bill, detail: "Refund", reason, amount: n.amount == null ? null : num(n.amount) };
    case "credit_note.issue":
      return { bill, detail: `Credit note ${str(n.number)}`.trim(), reason, amount: n.amount == null ? null : num(n.amount) };
    case "order.adjust":
      return { bill, detail: "Discount on bill", reason, amount: n.discount == null ? null : num(n.discount) };
    case "order.complimentary":
      return { bill, detail: str(n.kind) === "staff_meal" ? "Staff meal" : "Complimentary", reason, amount: n.value == null ? null : num(n.value) };
    case "approval.granted":
      return { bill: "", detail: `${str(n.approver)} approved ${str(n.permission)}`.trim(), reason: "", amount: null };
    default:
      return { bill, detail: "", reason, amount: null };
  }
}
