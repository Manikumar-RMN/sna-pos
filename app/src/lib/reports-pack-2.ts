/**
 * Pure helpers for the second set of report pages (pending KOT, pending bills, bills detail, void bills, settlement,
 * sales day book, month book, tax). They read the JSON that the migration 129 functions return, safely: a missing or
 * wrong-typed field becomes 0, "" or null, never an error. All totals come from the database, not from the rows.
 */

const num = (v: unknown) => {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};
const int = (v: unknown) => Math.max(0, Math.trunc(num(v)));
const text = (v: unknown, d = "") => (typeof v === "string" && v ? v : d);
const textOrNull = (v: unknown) => (typeof v === "string" && v ? v : null);
const list = (v: unknown): Record<string, unknown>[] =>
  Array.isArray(v) ? v.filter((x): x is Record<string, unknown> => !!x && typeof x === "object" && !Array.isArray(x)) : [];
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});

/** The 2000-row cap the database puts on the long lists. */
export type Capped = { truncated: boolean; rowLimit: number; totalRows: number };

function capped(o: Record<string, unknown>, shown: number): Capped {
  const totalRows = Math.max(shown, int(o.total_rows));
  return { truncated: o.truncated === true, rowLimit: int(o.row_limit) || 2000, totalRows };
}

/** "Showing first 2000 of 2105 bills; totals cover all." or null when nothing was cut off. */
export function truncationNote(c: Capped, noun: string): string | null {
  return c.truncated ? `Showing first ${c.rowLimit} of ${c.totalRows} ${noun}; totals cover all.` : null;
}

/** "5 min", "2 h 5 min", "1 d 3 h" for an age in minutes. */
export function ageText(minutes: number): string {
  const m = Math.max(0, Math.trunc(num(minutes)));
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  if (h < 24) return m % 60 ? `${h} h ${m % 60} min` : `${h} h`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d} d ${h % 24} h` : `${d} d`;
}

/** "cash" -> "Cash", "gift_card" -> "Gift card"; "" -> "Unspecified". */
export function methodLabel(v: unknown): string {
  const s = text(v).replace(/_/g, " ").trim();
  if (s.toLowerCase() === "upi") return "UPI";
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : "Unspecified";
}

/** "2026-10" -> "Oct 2026". Anything else is returned as it is. */
export function monthLabel(ym: string): string {
  const m = /^(\d{4})-(\d{2})$/.exec(ym);
  if (!m) return ym;
  const names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const i = Number(m[2]) - 1;
  return i >= 0 && i < 12 ? `${names[i]} ${m[1]}` : ym;
}

// ---------- pending KOT ----------

export type PendingKotItem = { name: string; quantity: number; status: string; note: string | null };
export type PendingKot = {
  ticketId: string;
  ticketNumber: string;
  station: string;
  ticketStatus: string;
  billNumber: string;
  orderStatus: string;
  branchId: string | null;
  outletName: string;
  table: string | null;
  orderType: string;
  kotTime: string | null;
  minutesPending: number;
  items: PendingKotItem[];
};

export function parsePendingKot(json: unknown): { rows: PendingKot[]; kots: number; items: number } {
  const o = obj(json);
  const rows = list(o.rows).map((r): PendingKot => ({
    ticketId: text(r.kitchen_ticket_id),
    ticketNumber: text(r.ticket_number, typeof r.ticket_number === "number" ? String(r.ticket_number) : ""),
    station: text(r.station),
    ticketStatus: text(r.ticket_status),
    billNumber: text(r.bill_number),
    orderStatus: text(r.order_status),
    branchId: textOrNull(r.branch_id),
    outletName: text(r.outlet_name, "Unknown outlet"),
    table: r.table_number == null || r.table_number === "" ? null : String(r.table_number),
    orderType: text(r.order_type),
    kotTime: textOrNull(r.kot_time),
    minutesPending: int(r.minutes_pending),
    items: list(r.items).map((i) => ({
      name: text(i.name, "Item"),
      quantity: num(i.quantity),
      status: text(i.status),
      note: textOrNull(i.note),
    })),
  }));
  const t = obj(o.totals);
  return { rows, kots: t.kots == null ? rows.length : int(t.kots), items: t.items == null ? rows.reduce((s, r) => s + r.items.length, 0) : int(t.items) };
}

// ---------- pending bills ----------

export type PendingBill = {
  kind: "open" | "unsettled";
  billNumber: string;
  orderStatus: string;
  paymentStatus: string;
  branchId: string | null;
  outletName: string;
  table: string | null;
  orderType: string;
  waiter: string | null;
  cashier: string | null;
  businessDate: string;
  createdAt: string | null;
  amount: number;
  paid: number;
  balance: number;
  ageMinutes: number;
};

export function parsePendingBills(json: unknown): { rows: PendingBill[]; totals: { bills: number; amount: number; paid: number; balance: number } } {
  const o = obj(json);
  const rows = list(o.rows).map((r): PendingBill => ({
    kind: r.kind === "unsettled" ? "unsettled" : "open",
    billNumber: text(r.bill_number),
    orderStatus: text(r.order_status),
    paymentStatus: text(r.payment_status),
    branchId: textOrNull(r.branch_id),
    outletName: text(r.outlet_name, "Unknown outlet"),
    table: r.table_number == null || r.table_number === "" ? null : String(r.table_number),
    orderType: text(r.order_type),
    waiter: textOrNull(r.waiter),
    cashier: textOrNull(r.cashier),
    businessDate: text(r.business_date),
    createdAt: textOrNull(r.created_at),
    amount: num(r.amount),
    paid: num(r.paid),
    balance: num(r.balance),
    ageMinutes: int(r.age_minutes),
  }));
  const t = obj(o.totals);
  return { rows, totals: { bills: t.bills == null ? rows.length : int(t.bills), amount: num(t.amount), paid: num(t.paid), balance: num(t.balance) } };
}

// ---------- bills detail ----------

export type BillPayment = { method: string; kind: string; amount: number };
export type BillDetail = {
  billNumber: string;
  businessDate: string;
  createdAt: string | null;
  branchId: string | null;
  outletName: string;
  table: string | null;
  orderType: string;
  waiter: string | null;
  cashier: string | null;
  covers: number | null;
  compKind: string | null;
  paymentStatus: string;
  subtotal: number;
  discount: number;
  serviceCharge: number;
  tax: number;
  rounding: number;
  grandTotal: number;
  payments: BillPayment[];
};
export type BillsDetailTotals = { bills: number; subtotal: number; discount: number; serviceCharge: number; tax: number; rounding: number; grandTotal: number };

function parsePayments(v: unknown): BillPayment[] {
  return list(v).map((p) => ({ method: text(p.method), kind: text(p.kind), amount: num(p.amount) }));
}

export function parseBillsDetail(json: unknown): { rows: BillDetail[]; cap: Capped; totals: BillsDetailTotals } {
  const o = obj(json);
  const rows = list(o.rows).map((r): BillDetail => ({
    billNumber: text(r.bill_number),
    businessDate: text(r.business_date),
    createdAt: textOrNull(r.created_at),
    branchId: textOrNull(r.branch_id),
    outletName: text(r.outlet_name, "Unknown outlet"),
    table: r.table_number == null || r.table_number === "" ? null : String(r.table_number),
    orderType: text(r.order_type),
    waiter: textOrNull(r.waiter),
    cashier: textOrNull(r.cashier),
    covers: r.covers == null ? null : int(r.covers),
    compKind: textOrNull(r.comp_kind),
    paymentStatus: text(r.payment_status),
    subtotal: num(r.subtotal),
    discount: num(r.discount),
    serviceCharge: num(r.service_charge),
    tax: num(r.tax),
    rounding: num(r.rounding),
    grandTotal: num(r.grand_total),
    payments: parsePayments(r.payments),
  }));
  const t = obj(o.totals);
  return {
    rows,
    cap: capped(o, rows.length),
    totals: {
      bills: t.bills == null ? rows.length : int(t.bills),
      subtotal: num(t.subtotal),
      discount: num(t.discount),
      serviceCharge: num(t.service_charge),
      tax: num(t.tax),
      rounding: num(t.rounding),
      grandTotal: num(t.grand_total),
    },
  };
}

/** "Cash 100.00 + UPI 50.00" style text; amounts are formatted by the caller's function. */
export function paymentsText(payments: BillPayment[], fmt: (n: number) => string): string {
  return payments.map((p) => `${methodLabel(p.method)} ${fmt(p.amount)}`).join(" + ");
}

/** Complimentary / staff-meal label for a bill, or "". */
export function compLabel(kind: string | null): string {
  if (!kind) return "";
  return kind === "staff_meal" ? "Staff meal" : kind === "complimentary" ? "Complimentary" : methodLabel(kind);
}

// ---------- void bills ----------

export type VoidBill = {
  billNumber: string;
  businessDate: string;
  voidedAt: string | null;
  branchId: string | null;
  outletName: string;
  table: string | null;
  orderType: string;
  voidedBy: string | null;
  reason: string | null;
  amount: number;
};

export function parseVoidBills(json: unknown): { rows: VoidBill[]; cap: Capped; totals: { bills: number; amount: number } } {
  const o = obj(json);
  const rows = list(o.rows).map((r): VoidBill => ({
    billNumber: text(r.bill_number),
    businessDate: text(r.business_date),
    voidedAt: textOrNull(r.voided_at),
    branchId: textOrNull(r.branch_id),
    outletName: text(r.outlet_name, "Unknown outlet"),
    table: r.table_number == null || r.table_number === "" ? null : String(r.table_number),
    orderType: text(r.order_type),
    voidedBy: textOrNull(r.voided_by),
    reason: textOrNull(r.reason),
    amount: num(r.amount),
  }));
  const t = obj(o.totals);
  return { rows, cap: capped(o, rows.length), totals: { bills: t.bills == null ? rows.length : int(t.bills), amount: num(t.amount) } };
}

// ---------- settlement ----------

export type ModeRow = { method: string; kind: string; payments: number; bills: number; amount: number; rounding: number };
export type RefundMode = { method: string; kind: string; count: number; amount: number };
export type SettlementPayment = {
  paidAt: string | null;
  billNumber: string;
  businessDate: string;
  branchId: string | null;
  outletName: string;
  method: string;
  kind: string;
  amount: number;
  rounding: number;
  referenceNo: string | null;
  receivedBy: string | null;
};
export type OutletModeRow = { branchId: string | null; outletName: string; method: string; kind: string; payments: number; bills: number; amount: number };
export type OutletRefundRow = { branchId: string | null; outletName: string; count: number; amount: number };
export type Settlement = {
  byMode: ModeRow[];
  byOutlet: OutletModeRow[];
  refunds: { count: number; amount: number; byMode: RefundMode[]; byOutlet: OutletRefundRow[] };
  rows: SettlementPayment[];
  cap: Capped;
  totals: { payments: number; amount: number; rounding: number; refunds: number; net: number };
};

export function parseSettlement(json: unknown): Settlement {
  const o = obj(json);
  const rows = list(o.rows).map((r): SettlementPayment => ({
    paidAt: textOrNull(r.paid_at),
    billNumber: text(r.bill_number),
    businessDate: text(r.business_date),
    branchId: textOrNull(r.branch_id),
    outletName: text(r.outlet_name, "Unknown outlet"),
    method: text(r.method),
    kind: text(r.kind),
    amount: num(r.amount),
    rounding: num(r.rounding),
    referenceNo: textOrNull(r.reference_no),
    receivedBy: textOrNull(r.received_by),
  }));
  const ref = obj(o.refunds);
  const t = obj(o.totals);
  return {
    byMode: list(o.by_mode).map((r) => ({
      method: text(r.method),
      kind: text(r.kind),
      payments: int(r.payments),
      bills: int(r.bills),
      amount: num(r.amount),
      rounding: num(r.rounding),
    })),
    byOutlet: list(o.by_outlet).map((r) => ({
      branchId: textOrNull(r.branch_id),
      outletName: text(r.outlet_name, "Unknown outlet"),
      method: text(r.method),
      kind: text(r.kind),
      payments: int(r.payments),
      bills: int(r.bills),
      amount: num(r.amount),
    })),
    refunds: {
      count: int(ref.count),
      amount: num(ref.amount),
      byMode: list(ref.by_mode).map((r) => ({ method: text(r.method), kind: text(r.kind), count: int(r.count), amount: num(r.amount) })),
      byOutlet: list(ref.by_outlet).map((r) => ({ branchId: textOrNull(r.branch_id), outletName: text(r.outlet_name, "Unknown outlet"), count: int(r.count), amount: num(r.amount) })),
    },
    rows,
    cap: capped(o, rows.length),
    totals: {
      payments: t.payments == null ? rows.length : int(t.payments),
      amount: num(t.amount),
      rounding: num(t.rounding),
      refunds: num(t.refunds),
      net: num(t.net),
    },
  };
}

// ---------- day book / month book ----------

export type BookRow = {
  /** 'YYYY-MM-DD' for the day book, 'YYYY-MM' for the month book. */
  key: string;
  /** Days with sales in the month (month book only; 0 for the day book). */
  days: number;
  bills: number;
  compBills: number;
  gross: number;
  discount: number;
  serviceCharge: number;
  tax: number;
  rounding: number;
  netSales: number;
  grandTotal: number;
  cash: number;
  nonCash: number;
  unpaid: number;
};

function bookRow(r: Record<string, unknown>, key: string): BookRow {
  return {
    key,
    days: int(r.days),
    bills: int(r.bills),
    compBills: int(r.comp_bills),
    gross: num(r.gross),
    discount: num(r.discount),
    serviceCharge: num(r.service_charge),
    tax: num(r.tax),
    rounding: num(r.rounding),
    netSales: num(r.net_sales),
    grandTotal: num(r.grand_total),
    cash: num(r.cash),
    nonCash: num(r.non_cash),
    unpaid: num(r.unpaid),
  };
}

/** report_sales_day_book (field "business_date") or report_sales_month_book (field "month"). */
export function parseBook(json: unknown, field: "business_date" | "month"): { rows: BookRow[]; totals: BookRow } {
  const o = obj(json);
  const rows = list(o.rows).map((r) => bookRow(r, text(r[field])));
  return { rows, totals: bookRow(obj(o.totals), "TOTAL") };
}

/** Months in the range that are only partly covered: the first one when the range starts after day 1, the last when it ends before the month's last day. */
export function partialMonths(from: string, to: string): { first: string | null; last: string | null } {
  const ok = (s: string) => /^\d{4}-\d{2}-\d{2}$/.test(s);
  if (!ok(from) || !ok(to)) return { first: null, last: null };
  const lastDay = (ymd: string) => {
    const [y, m] = ymd.split("-").map(Number);
    return new Date(Date.UTC(y, m, 0)).getUTCDate();
  };
  const first = from.slice(8) !== "01" ? from.slice(0, 7) : null;
  const last = Number(to.slice(8)) !== lastDay(to) ? to.slice(0, 7) : null;
  return { first, last };
}

// ---------- tax ----------

export type TaxLine = { component: string; rate: number; taxable: number; tax: number };
export type TaxOutletLine = TaxLine & { branchId: string | null; outletName: string };
export type TaxReport = {
  rows: TaxLine[];
  byOutlet: TaxOutletLine[];
  totals: { taxable: number; tax: number; ordersTaxTotal: number; taxIncluded: number; exemptSales: number };
  /** Tax reversed by credit notes issued in the period, shown on its own lines. */
  creditRows: TaxLine[];
  credit: { count: number; amount: number; tax: number };
};

export function parseTax(json: unknown): TaxReport {
  const o = obj(json);
  const t = obj(o.totals);
  return {
    rows: list(o.rows).map((r) => ({ component: text(r.component, "Tax"), rate: num(r.rate), taxable: num(r.taxable), tax: num(r.tax) })),
    byOutlet: list(o.by_outlet).map((r) => ({
      branchId: textOrNull(r.branch_id),
      outletName: text(r.outlet_name, "Unknown outlet"),
      component: text(r.component, "Tax"),
      rate: num(r.rate),
      taxable: num(r.taxable),
      tax: num(r.tax),
    })),
    totals: { taxable: num(t.taxable), tax: num(t.tax), ordersTaxTotal: num(t.orders_tax_total), taxIncluded: num(t.tax_included), exemptSales: num(t.exempt_sales) },
    creditRows: list(o.credit_rows).map((r) => ({ component: text(r.component, "Tax"), rate: num(r.rate), taxable: num(r.taxable), tax: num(r.tax) })),
    credit: { count: num(obj(o.credit_totals).count), amount: num(obj(o.credit_totals).amount), tax: num(obj(o.credit_totals).tax) },
  };
}

/** True when the tax added up from the tax lines differs from the tax on the bill headers by a cent or more. */
export function taxTotalsDiffer(t: { tax: number; ordersTaxTotal: number }): boolean {
  return Math.abs(t.tax - t.ordersTaxTotal) >= 0.01;
}

/** One line per outlet for the settlement page: payments and amount collected, refunds given, and the net. Outlets keep the order the database gave. */
export type SettlementOutletTotal = { outletName: string; payments: number; amount: number; refundCount: number; refunds: number; net: number };
export function settlementByOutlet(s: Pick<Settlement, "byOutlet" | "refunds">): SettlementOutletTotal[] {
  const map = new Map<string, SettlementOutletTotal>();
  const get = (key: string, outletName: string) => {
    let e = map.get(key);
    if (!e) {
      e = { outletName, payments: 0, amount: 0, refundCount: 0, refunds: 0, net: 0 };
      map.set(key, e);
    }
    return e;
  };
  for (const r of s.byOutlet) {
    const e = get(r.branchId ?? r.outletName, r.outletName);
    e.payments += r.payments;
    e.amount += r.amount;
  }
  for (const r of s.refunds.byOutlet) {
    const e = get(r.branchId ?? r.outletName, r.outletName);
    e.refundCount += r.count;
    e.refunds += r.amount;
  }
  const out = [...map.values()];
  for (const e of out) e.net = e.amount - e.refunds;
  return out;
}

/**
 * Rows for the Excel (CSV) file: the report rows, then a TOTAL row built from the database totals (when there is one),
 * then, when the database cut the list short, a final line saying so. Rows are padded to the header width.
 */
export function csvWithFooter(
  width: number,
  rows: (string | number)[][],
  total: (string | number)[] | null,
  cap: Capped | null,
): (string | number)[][] {
  const pad = (r: (string | number)[]): (string | number)[] => (r.length >= width ? r : [...r, ...Array<string>(width - r.length).fill("")]);
  const out = [...rows];
  if (total) out.push(pad(total));
  if (cap?.truncated) out.push(pad([`Truncated: showing first ${cap.rowLimit} of ${cap.totalRows}`]));
  return out;
}
