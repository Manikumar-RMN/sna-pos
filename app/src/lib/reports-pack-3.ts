/**
 * Pure helpers for the third set of report pages (cover analysis, reprints, tips). They read the JSON that the
 * migration 138 functions return (report_covers, report_reprints, report_tips), safely: a missing or wrong-typed
 * field becomes 0, "" or null, never an error. All totals come from the database, not from the rows.
 */

const num = (v: unknown) => {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};
const numOrNull = (v: unknown): number | null => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
const int = (v: unknown) => Math.max(0, Math.trunc(num(v)));
const text = (v: unknown, d = "") => (typeof v === "string" && v ? v : d);
const textOrNull = (v: unknown) => (typeof v === "string" && v ? v : null);
const list = (v: unknown): Record<string, unknown>[] =>
  Array.isArray(v) ? v.filter((x): x is Record<string, unknown> => !!x && typeof x === "object" && !Array.isArray(x)) : [];
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});

// ---------- cover analysis (report_covers) ----------

export type CoverRow = {
  /** Day (YYYY-MM-DD), outlet name or staff name, whichever the table is grouped by. */
  label: string;
  outletName: string;
  bills: number;
  covers: number;
  /** Null when the person may not see money. */
  sales: number | null;
  salesPerCover: number | null;
};
export type CoverTotals = {
  bills: number;
  billsWithCovers: number;
  billsWithoutCovers: number;
  covers: number;
  sales: number | null;
  salesPerCover: number | null;
};
export type CoverReport = { money: boolean; byDay: CoverRow[]; byOutlet: CoverRow[]; byWaiter: CoverRow[]; totals: CoverTotals };

export function parseCovers(json: unknown): CoverReport {
  const o = obj(json);
  const row = (r: Record<string, unknown>, label: string): CoverRow => ({
    label,
    outletName: text(r.outlet_name, "Unknown outlet"),
    bills: int(r.bills),
    covers: int(r.covers),
    sales: numOrNull(r.sales),
    salesPerCover: numOrNull(r.sales_per_cover),
  });
  const t = obj(o.totals);
  return {
    money: o.money === true,
    byDay: list(o.by_day).map((r) => row(r, text(r.business_date))),
    byOutlet: list(o.by_outlet).map((r) => row(r, text(r.outlet_name, "Unknown outlet"))),
    byWaiter: list(o.by_waiter).map((r) => row(r, text(r.staff_name, "Unknown"))),
    totals: {
      bills: int(t.bills),
      billsWithCovers: int(t.bills_with_covers),
      billsWithoutCovers: int(t.bills_without_covers),
      covers: int(t.covers),
      sales: numOrNull(t.sales),
      salesPerCover: numOrNull(t.sales_per_cover),
    },
  };
}

/** "3 of 8 bills had no guest count." or "" when every bill had one. */
export function coversMissingNote(t: Pick<CoverTotals, "bills" | "billsWithoutCovers">): string {
  if (t.billsWithoutCovers <= 0) return "";
  return `${t.billsWithoutCovers} of ${t.bills} dine-in bill${t.bills === 1 ? "" : "s"} had no guest count; they are not in the covers or the sales per cover.`;
}

// ---------- reprints (report_reprints) ----------

export type Reprint = {
  id: string;
  at: string | null;
  kind: "bill" | "kot";
  userName: string;
  outletName: string;
  billNumber: string | null;
  table: string | null;
  detail: string;
};
export type ReprintUser = { userName: string; bills: number; kots: number };
export type ReprintReport = {
  rows: Reprint[];
  byUser: ReprintUser[];
  cap: { truncated: boolean; rowLimit: number; totalRows: number };
  totals: { reprints: number; bills: number; kots: number };
};

/** What the audit row's new_value says about one reprint, in words: "Reprint 2", "2 tickets", or "". */
export function reprintDetailText(kind: "bill" | "kot", detail: unknown): string {
  const d = obj(detail);
  const parts: string[] = [];
  const no = numOrNull(d.reprint_no ?? d.count ?? d.n);
  if (no !== null && no > 0) parts.push(`Reprint ${Math.trunc(no)}`);
  const ids = Array.isArray(d.ticket_ids) ? d.ticket_ids.length : numOrNull(d.tickets) ?? 0;
  if (kind === "kot" && ids > 0) parts.push(`${Math.trunc(ids)} ticket${Math.trunc(ids) === 1 ? "" : "s"}`);
  const why = text(d.reason);
  if (why) parts.push(why);
  const by = text(d.approver ?? d.approved_by);
  if (by) parts.push(`approved by ${by}`);
  return parts.join(", ");
}

export function parseReprints(json: unknown): ReprintReport {
  const o = obj(json);
  const rows = list(o.rows).map((r): Reprint => {
    const kind = r.kind === "kot" || r.action === "kot.reprint" ? "kot" : "bill";
    return {
      id: String(r.id ?? ""),
      at: textOrNull(r.at),
      kind,
      userName: text(r.user_name, "Unknown"),
      outletName: text(r.outlet_name, "Unknown outlet"),
      billNumber: textOrNull(r.bill_number),
      table: textOrNull(r.table_number),
      detail: reprintDetailText(kind, r.detail),
    };
  });
  const t = obj(o.totals);
  return {
    rows,
    byUser: list(o.by_user).map((r) => ({ userName: text(r.user_name, "Unknown"), bills: int(r.bills), kots: int(r.kots) })),
    cap: { truncated: o.truncated === true, rowLimit: int(o.row_limit) || 2000, totalRows: Math.max(rows.length, int(o.total_rows)) },
    totals: { reprints: int(t.reprints), bills: int(t.bills), kots: int(t.kots) },
  };
}

// ---------- tips (report_tips) ----------

export type TipGroup = { label: string; outletName: string; tips: number; amount: number };
export type TipReport = {
  byDay: TipGroup[];
  byMethod: TipGroup[];
  byWaiter: TipGroup[];
  byOutlet: TipGroup[];
  totals: { tips: number; amount: number; bills: number };
};

export function parseTips(json: unknown): TipReport {
  const o = obj(json);
  const g = (r: Record<string, unknown>, label: string): TipGroup => ({
    label,
    outletName: text(r.outlet_name, "Unknown outlet"),
    tips: int(r.tips),
    amount: num(r.amount),
  });
  const t = obj(o.totals);
  return {
    byDay: list(o.by_day).map((r) => g(r, text(r.business_date))),
    byMethod: list(o.by_method).map((r) => g(r, methodName(r.method))),
    byWaiter: list(o.by_waiter).map((r) => g(r, text(r.staff_name, "Unknown"))),
    byOutlet: list(o.by_outlet).map((r) => g(r, text(r.outlet_name, "Unknown outlet"))),
    totals: { tips: int(t.tips), amount: num(t.amount), bills: int(t.bills) },
  };
}

function methodName(v: unknown): string {
  return text(v, "Unspecified");
}

// ---------- shared ----------

/** Bill payment status in plain words for the Note column: "partially_refunded" -> "Partly refunded", "unpaid" -> "Unpaid". "paid" -> "". */
export function paymentStatusLabel(v: string | null | undefined): string {
  switch ((v ?? "").trim().toLowerCase()) {
    case "":
    case "paid":
      return "";
    case "unpaid":
      return "Unpaid";
    case "partial":
      return "Part paid";
    case "refunded":
      return "Refunded";
    case "partially_refunded":
      return "Partly refunded";
    default: {
      const s = String(v).replace(/_/g, " ").trim();
      return s.charAt(0).toUpperCase() + s.slice(1);
    }
  }
}

/** "1 bill" / "3 bills". */
export function plural(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`;
}
