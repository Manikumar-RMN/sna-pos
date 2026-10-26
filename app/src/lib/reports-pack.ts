/**
 * Pure helpers for the report pages under /reports (popular / slow items, waiter-wise
 * sales, discount summary, cancel and void audit) and their outlet scope. No database
 * access here, so every rule can be unit-tested.
 */
import { addDays, isYmd } from "./format";
import type { DbErrorLike } from "./db-error";

const r2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;
const num = (v: unknown) => {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};

/** Longest range (in days from first to last day) the report functions accept. */
export const MAX_RANGE_DAYS = 366;

/** Same range presets as the main Reports page; `today` is the business day. */
export function resolveRange(
  today: string,
  sp: { range?: string; from?: string; to?: string },
): { from: string; to: string; range: string; clamped?: true } {
  let from = today;
  let to = today;
  let range = sp.range ?? "today";
  let clamped = false;
  if (isYmd(sp.from) && isYmd(sp.to)) {
    from = sp.from <= sp.to ? sp.from : sp.to;
    to = sp.from <= sp.to ? sp.to : sp.from;
    range = "custom";
    // The report functions refuse more than 366 days; keep the latest 366 days instead of failing.
    if (from < addDays(to, -MAX_RANGE_DAYS)) {
      from = addDays(to, -MAX_RANGE_DAYS);
      clamped = true;
    }
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
  return clamped ? { from, to, range, clamped: true } : { from, to, range };
}

/** Keeps the chosen date range when moving between report pages ("" for the default, today). */
export function rangeQuery(sp: { range?: string; from?: string; to?: string }): string {
  if (isYmd(sp.from) && isYmd(sp.to)) return `?from=${sp.from}&to=${sp.to}`;
  if (sp.range && ["yesterday", "7d", "month", "lastmonth"].includes(sp.range)) return `?range=${sp.range}`;
  return "";
}

// ---------- outlet scope ----------

/** The part of `my_outlets` the reports need. */
export type OutletsLite = { current: string; all_outlets: boolean; outlets: { id: string; name: string }[] };
export type OutletScope = {
  /** True when the outlet picker is on "All outlets". */
  all: boolean;
  /** The one outlet to read, or null for every outlet. */
  branchId: string | null;
  /** "All outlets" or "Outlet: <name>". */
  label: string;
  /** Outlet names by id, for an Outlet column. */
  names: Map<string, string>;
  /** How many outlets the person can see. */
  count: number;
};

/** Works out which outlet(s) a report covers from `my_outlets` (falls back to the signed-in outlet when it is missing). */
export function outletScope(info: OutletsLite | null | undefined, fallback: { id: string; name: string }): OutletScope {
  const outlets = info?.outlets?.length ? info.outlets : [{ id: fallback.id, name: fallback.name }];
  const names = new Map(outlets.map((o) => [o.id, o.name]));
  const all = !!info?.all_outlets;
  const current = info?.current || fallback.id;
  return {
    all,
    branchId: all ? null : current,
    label: all ? "All outlets" : `Outlet: ${names.get(current) ?? fallback.name}`,
    names,
    count: outlets.length,
  };
}

// ---------- RPC results (migration 128) ----------
// The totals are worked out in the database (report_popular_items, report_unsold_items, report_waiter_sales,
// report_discounts), so the app only reads their JSON safely and merges a few rows for display.

/** Errors the report functions raise on purpose; they are already plain words and are shown as they are. */
const PLAIN_RPC_ERROR = /^(You do not have the right|Your role does not allow|You are not signed in|Choose a )/;

/** Makes a report function's error readable: its own plain messages pass through, the rest go through friendlyDbError. */
export function reportRpcError(e: DbErrorLike | null | undefined): DbErrorLike | null {
  if (!e) return null;
  const msg = String(e.message ?? "").replace(/^[^]*?ERROR:\s*/, "").trim();
  return PLAIN_RPC_ERROR.test(msg) ? { message: msg, code: "P0001" } : e;
}

const list = (v: unknown): Record<string, unknown>[] =>
  Array.isArray(v) ? v.filter((x): x is Record<string, unknown> => !!x && typeof x === "object" && !Array.isArray(x)) : [];
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const text = (v: unknown, d = "") => (typeof v === "string" && v ? v : d);
const idOrNull = (v: unknown) => (typeof v === "string" && v ? v : null);

export type ItemSale = { key: string; name: string; qty: number; amount: number };

/** report_popular_items: best first. */
export function parsePopular(json: unknown): ItemSale[] {
  return list(json).map((r) => ({
    key: idOrNull(r.product_id) ?? `name:${text(r.name)}`,
    name: text(r.name, "Unknown item"),
    qty: num(r.units),
    amount: num(r.amount),
  }));
}

/** report_unsold_items: active items with no sale, and the active items that sold least. */
export function parseUnsold(json: unknown): { dead: { id: string; name: string }[]; slow: ItemSale[] } {
  const o = obj(json);
  return {
    dead: list(o.unsold).map((r) => ({ id: text(r.id), name: text(r.name, "Unknown item") })),
    slow: parsePopular(o.sold_least),
  };
}

export type WaiterRow = { branch_id: string | null; outlet_name: string; user_id: string | null; name: string; bills: number; covers: number; total: number; average: number };

/** report_waiter_sales: one row per outlet per staff member, biggest sales first. */
export function parseWaiters(json: unknown): WaiterRow[] {
  return list(json).map((r) => {
    const bills = Math.max(0, Math.trunc(num(r.bills)));
    const total = num(r.sales);
    return {
      branch_id: idOrNull(r.branch_id),
      outlet_name: text(r.outlet_name, "Unknown outlet"),
      user_id: idOrNull(r.user_id),
      name: text(r.staff_name, "Unknown"),
      bills,
      covers: Math.max(0, Math.trunc(num(r.covers))),
      total,
      average: bills ? r2(total / bills) : 0,
    };
  });
}

export type DiscountGroup = { key: string; name: string; bills: number; total: number; maxPercent: number };
export type DiscountReport = { byCashier: DiscountGroup[]; byDay: DiscountGroup[]; byOutlet: DiscountGroup[] };

/** report_discounts. By-cashier rows come per outlet; use `mergeCashiers` to combine a person across outlets. */
export function parseDiscounts(json: unknown): DiscountReport {
  const o = obj(json);
  const group = (r: Record<string, unknown>, key: string, name: string): DiscountGroup => ({
    key,
    name,
    bills: Math.trunc(num(r.bills)),
    total: num(r.total),
    maxPercent: num(r.max_pct),
  });
  return {
    byCashier: list(o.by_cashier).map((r) => group(r, idOrNull(r.user_id) ?? `name:${text(r.name)}`, text(r.name, "Unknown"))),
    byDay: list(o.by_day).map((r) => group(r, text(r.business_date), text(r.business_date))),
    byOutlet: list(o.by_outlet).map((r) => group(r, idOrNull(r.branch_id) ?? "", text(r.outlet_name, "Unknown outlet"))),
  };
}

/** Adds a cashier's rows from several outlets together (bills and total added, highest percent kept). Biggest total first. */
export function mergeCashiers(rows: DiscountGroup[]): DiscountGroup[] {
  const map = new Map<string, DiscountGroup>();
  for (const g of rows) {
    const cur = map.get(g.key);
    if (cur) {
      cur.bills += g.bills;
      cur.total += g.total;
      cur.maxPercent = Math.max(cur.maxPercent, g.maxPercent);
    } else {
      map.set(g.key, { ...g });
    }
  }
  return [...map.values()]
    .map((g) => ({ ...g, total: r2(g.total) }))
    .sort((a, b) => b.total - a.total || a.name.localeCompare(b.name));
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
  "bill.print": "Bill printed",
  "bill.reprint": "Bill reprinted",
  "kot.reprint": "Kitchen ticket reprinted",
  "order.tip": "Tip recorded",
  "order.open_price": "Open-priced item sold",
  "order.move_item": "Item moved to another table",
  "menu.bulk_price_change": "Prices changed in bulk",
  "menu.bulk_price_undo": "Bulk price change undone",
  "role.rights_copied": "Role rights copied",
  "user.access_copied": "Staff access copied",
  "tax.rate_scheduled": "Tax rate change scheduled",
  "tax.rate_schedule_cancelled": "Scheduled tax change cancelled",
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
    case "order.tip":
      return { bill, detail: "Tip", reason, amount: n.amount == null ? null : num(n.amount) };
    case "order.open_price":
      return { bill, detail: `${str(n.qty) || "1"} × ${str(n.product ?? n.item)}`.trim(), reason, amount: n.price == null ? null : num(n.price) };
    case "bill.print":
    case "bill.reprint":
    case "kot.reprint":
      return { bill, detail: AUDIT_ACTION_LABEL[action] ?? "", reason, amount: null };
    default:
      return { bill, detail: "", reason, amount: null };
  }
}
