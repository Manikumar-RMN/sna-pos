/**
 * Customers screen helpers: reading what the database functions customer_list / customer_detail return, the list
 * filters and sorts, CSV export, and the checks for the edit form and the loyalty rules form.
 *
 * Pure functions only (no database calls), so they can be tested without a server. The money and point figures are
 * worked out by the database; nothing here recalculates visits, spend or points.
 */

export type CustomerFilter = "all" | "repeat" | "new" | "lapsed" | "never";
export type CustomerSort = "last_visit" | "spend" | "visits" | "points" | "name";

export const CUSTOMER_FILTERS: { key: CustomerFilter; label: string; help: string }[] = [
  { key: "all", label: "All", help: "Every guest" },
  { key: "repeat", label: "Repeat", help: "2 or more visits" },
  { key: "new", label: "New", help: "Exactly 1 visit" },
  { key: "lapsed", label: "Lapsed", help: "Last visit more than 60 days ago" },
  { key: "never", label: "Never visited", help: "In the list but no paid bill yet" },
];

export const CUSTOMER_SORTS: { key: CustomerSort; label: string }[] = [
  { key: "last_visit", label: "Last visit" },
  { key: "spend", label: "Spend" },
  { key: "visits", label: "Visits" },
  { key: "points", label: "Points" },
  { key: "name", label: "Name" },
];

/** Rows per page on the list (the database allows up to 200). */
export const PAGE_SIZE = 50;
/** Rows per request while exporting (the database maximum). */
export const EXPORT_PAGE_SIZE = 200;
/** The export stops here so one click cannot read an endless list. */
export const EXPORT_MAX_ROWS = 20000;
/** The search needs at least this many characters (the database ignores shorter text). */
export const MIN_SEARCH_CHARS = 3;
/** A guest is "lapsed" after this many days without a visit (same number as the database). */
export const LAPSED_DAYS = 60;

export function parseFilter(v: unknown): CustomerFilter {
  return CUSTOMER_FILTERS.some((f) => f.key === v) ? (v as CustomerFilter) : "all";
}
export function parseSort(v: unknown): CustomerSort {
  return CUSTOMER_SORTS.some((s) => s.key === v) ? (v as CustomerSort) : "last_visit";
}
/** Page number from the address bar: 1 or more, whole numbers only. */
export function parsePage(v: unknown): number {
  const n = Number(Array.isArray(v) ? v[0] : v);
  return Number.isInteger(n) && n >= 1 && n <= 100000 ? n : 1;
}
/** First text value of a search parameter (Next gives an array when the key repeats). */
export function firstParam(v: string | string[] | undefined): string {
  return (Array.isArray(v) ? v[0] : v) ?? "";
}

/** The search text, trimmed. Empty when too short to search (the list then shows everyone). */
export function searchText(q: string): string {
  const t = q.trim().replace(/\s+/g, " ").slice(0, 60);
  return t.length >= MIN_SEARCH_CHARS ? t : "";
}
/** A hint while typing 1 or 2 characters. */
export function searchHint(q: string): string | null {
  const n = q.trim().length;
  return n > 0 && n < MIN_SEARCH_CHARS ? `Type at least ${MIN_SEARCH_CHARS} letters or digits to search.` : null;
}

// ---------------------------------------------------------------- reading database answers

const num = (v: unknown, d = 0): number => {
  const n = typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : d;
};
const numOrNull = (v: unknown): number | null => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
const str = (v: unknown): string => (typeof v === "string" ? v : v == null ? "" : String(v));
const strOrNull = (v: unknown): string | null => (v == null || v === "" ? null : String(v));
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

export type CustomerRow = {
  id: string;
  name: string;
  phone: string;
  visits: number;
  spend: number;
  avgBill: number;
  firstVisitOn: string | null;
  lastVisitOn: string | null;
  points: number;
  marketingConsent: boolean;
};

function parseRow(raw: unknown): CustomerRow | null {
  const r = obj(raw);
  const id = str(r.id);
  if (!id) return null;
  return {
    id,
    name: str(r.name) || "Guest",
    phone: str(r.phone),
    visits: num(r.visits),
    spend: num(r.spend),
    avgBill: num(r.avg_bill),
    firstVisitOn: strOrNull(r.first_visit_on),
    lastVisitOn: strOrNull(r.last_visit_on),
    points: num(r.points),
    marketingConsent: r.marketing_consent === true,
  };
}

/** customer_list returns {total, rows:[...]}. Anything else gives an empty list. */
export function parseCustomerList(raw: unknown): { total: number; rows: CustomerRow[] } {
  const o = obj(raw);
  const rows = arr(o.rows).map(parseRow).filter((r): r is CustomerRow => r !== null);
  return { total: Math.max(num(o.total, rows.length), rows.length), rows };
}

export type CustomerBill = {
  id: string;
  billNumber: string;
  businessDate: string | null;
  outlet: string | null;
  total: number;
  refunded: number;
  paymentMode: string | null;
  pointsEarned: number;
  pointsRedeemed: number;
  /** "paid", "unpaid", "partially_refunded" ... (payment_status) and whether the bill counts as a visit. */
  paymentStatus: string | null;
  status: string | null;
  isVisit: boolean;
};
export type LedgerEntry = { at: string | null; kind: string; points: number; billNumber: string | null; note: string | null };
export type CustomerDetail = {
  id: string;
  name: string;
  phone: string;
  email: string | null;
  notes: string | null;
  birthday: string | null;
  marketingConsent: boolean;
  consentGivenAt: string | null;
  visits: number;
  spend: number;
  avgBill: number;
  firstVisitOn: string | null;
  lastVisitOn: string | null;
  points: number;
  /** Words from the database about points expiry, when it sends them. */
  expiryNote: string | null;
  /** Money this guest owes on a credit account, when they have one. */
  accountBalance: number | null;
  bills: CustomerBill[];
  ledger: LedgerEntry[];
};

/**
 * customer_detail (migration 145) returns {profile{id,name,phone,email,notes,date_of_birth,marketing_consent,consent_given_at,...},
 * stats{visits,spend,avg_bill,first_visit_on,last_visit_on}, points_balance, points_expire, points_note, account_balance, bills[], ledger[]}.
 * The reader also accepts the profile and stats fields at the top level, so a small change in the database answer does not blank the screen.
 */
export function parseCustomerDetail(raw: unknown): CustomerDetail | null {
  const o = obj(raw);
  const p = Object.keys(obj(o.profile)).length ? obj(o.profile) : o;
  const s = Object.keys(obj(o.stats)).length ? obj(o.stats) : p;
  const id = str(p.id);
  if (!id) return null;
  const pointsRaw = o.points_balance ?? (o.points !== undefined && typeof o.points !== "object" ? o.points : (obj(o.points).balance ?? p.points ?? s.points));
  return {
    id,
    name: str(p.name) || "Guest",
    phone: str(p.phone),
    email: strOrNull(p.email),
    notes: strOrNull(p.notes),
    birthday: strOrNull(p.birthday ?? p.date_of_birth),
    marketingConsent: p.marketing_consent === true,
    consentGivenAt: strOrNull(p.consent_given_at),
    visits: num(s.visits),
    spend: num(s.spend),
    avgBill: num(s.avg_bill),
    firstVisitOn: strOrNull(s.first_visit_on),
    lastVisitOn: strOrNull(s.last_visit_on),
    points: num(pointsRaw),
    expiryNote: strOrNull(o.points_note ?? o.expiry_note ?? obj(o.points).expiry_note),
    accountBalance: numOrNull(o.account_balance),
    bills: arr(o.bills).map((b) => {
      const r = obj(b);
      return {
        id: str(r.id),
        billNumber: str(r.bill_number),
        businessDate: strOrNull(r.business_date),
        outlet: strOrNull(r.outlet),
        total: num(r.total),
        refunded: num(r.refunded),
        paymentMode: strOrNull(r.payment_mode),
        pointsEarned: num(r.points_earned),
        pointsRedeemed: num(r.points_redeemed),
        paymentStatus: strOrNull(r.payment_status),
        status: strOrNull(r.status),
        isVisit: r.is_visit !== false,
      };
    }).filter((b) => b.id !== ""),
    ledger: arr(o.ledger).map((l) => {
      const r = obj(l);
      return { at: strOrNull(r.at ?? r.created_at), kind: str(r.kind), points: num(r.points), billNumber: strOrNull(r.bill_number), note: strOrNull(r.note) };
    }),
  };
}

// ---------------------------------------------------------------- showing values

/** The phone as typed on the bill, grouped for reading: "98765 43210", "+91 98765 43210". Short or odd numbers stay as they are. */
export function formatPhone(phone: string | null | undefined): string {
  const p = (phone ?? "").trim();
  if (!p) return "—";
  const digits = p.replace(/[^0-9]/g, "");
  if (!/^\+?[0-9 ()-]+$/.test(p) || digits.length < 8) return p;
  const plus = p.startsWith("+") ? "+" : "";
  if (digits.length <= 10) return digits.length === 10 ? `${digits.slice(0, 5)} ${digits.slice(5)}` : p;
  const cc = digits.slice(0, digits.length - 10);
  const local = digits.slice(-10);
  return `${plus}${cc} ${local.slice(0, 5)} ${local.slice(5)}`;
}

/** Whole days from `ymd` to `today` (both YYYY-MM-DD). Null when either date is missing. */
export function daysBetween(ymd: string | null | undefined, today: string): number | null {
  if (!ymd || !/^\d{4}-\d{2}-\d{2}$/.test(ymd) || !/^\d{4}-\d{2}-\d{2}$/.test(today)) return null;
  const a = Date.parse(ymd + "T00:00:00Z");
  const b = Date.parse(today + "T00:00:00Z");
  return Number.isFinite(a) && Number.isFinite(b) ? Math.round((b - a) / 86400000) : null;
}

/** "Today", "Yesterday", "12 days ago", "3 months ago", or "Never". */
export function lastVisitText(ymd: string | null | undefined, today: string): string {
  const d = daysBetween(ymd, today);
  if (d === null) return "Never";
  if (d <= 0) return "Today";
  if (d === 1) return "Yesterday";
  if (d < 60) return `${d} days ago`;
  const months = Math.floor(d / 30);
  return months < 24 ? `${months} months ago` : `${Math.floor(d / 365)} years ago`;
}

/** Same rule as the Lapsed filter. */
export function isLapsed(lastVisitOn: string | null | undefined, today: string): boolean {
  const d = daysBetween(lastVisitOn, today);
  return d !== null && d > LAPSED_DAYS;
}

/** A short label for a points ledger line. */
export function ledgerKindLabel(kind: string): string {
  switch (kind) {
    case "earn": return "Earned";
    case "redeem": return "Used on a bill";
    case "reverse": return "Taken back (refund)";
    case "adjust": return "Adjusted";
    case "expire": return "Expired";
    default: return kind || "Other";
  }
}

/** Points with a sign for the ledger: "+12", "−40". */
export function signedPoints(n: number): string {
  if (n > 0) return `+${n}`;
  if (n < 0) return `−${Math.abs(n)}`;
  return "0";
}

/** The list address for a set of options. Default values are left out so links stay short. */
export function customersHref(o: { q?: string; filter?: CustomerFilter; sort?: CustomerSort; page?: number }): string {
  const p = new URLSearchParams();
  const q = (o.q ?? "").trim();
  if (q) p.set("q", q);
  if (o.filter && o.filter !== "all") p.set("filter", o.filter);
  if (o.sort && o.sort !== "last_visit") p.set("sort", o.sort);
  if (o.page && o.page > 1) p.set("page", String(o.page));
  const s = p.toString();
  return s ? `/customers?${s}` : "/customers";
}

// ---------------------------------------------------------------- CSV export

export const CUSTOMER_CSV_HEADER = ["Name", "Phone", "Visits", "Spend", "Average bill", "First visit", "Last visit", "Points", "Agreed to offers"];

export function customerCsvRows(rows: CustomerRow[]): (string | number)[][] {
  return rows.map((r) => [r.name, r.phone, r.visits, r.spend, r.avgBill, r.firstVisitOn ?? "", r.lastVisitOn ?? "", r.points, r.marketingConsent ? "Yes" : "No"]);
}

/** One CSV cell: quoted when needed, and text that would run as a spreadsheet formula is made plain. */
export function csvCell(v: string | number): string {
  let s = String(v ?? "");
  if (typeof v === "string" && /^[=+\-@\t\r]/.test(s)) s = "'" + s;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

/** The whole file text, with the byte-order mark Excel needs to read names in any language. */
export function toCsv(header: string[], rows: (string | number)[][]): string {
  return "﻿" + [header, ...rows].map((r) => r.map(csvCell).join(",")).join("\r\n");
}

export function exportFilename(today: string, filter: CustomerFilter): string {
  return `customers_${filter}_${today}.csv`;
}

// ---------------------------------------------------------------- forms

export type CustomerEditInput = { name: string; email: string; notes: string; birthday: string; consent: boolean };

/** Checks the edit form. Returns the cleaned values, or one sentence saying what to fix. */
export function validateCustomerEdit(i: CustomerEditInput, today: string):
  | { ok: true; name: string; email: string | null; notes: string | null; birthday: string | null; consent: boolean }
  | { ok: false; error: string } {
  const name = i.name.trim().replace(/\s+/g, " ");
  if (name.length < 1 || name.length > 80) return { ok: false, error: "Enter the guest's name (up to 80 letters)." };
  const email = i.email.trim();
  if (email && (email.length > 120 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) return { ok: false, error: "That email address does not look right." };
  const notes = i.notes.trim();
  if (notes.length > 500) return { ok: false, error: "Notes can be at most 500 characters." };
  const birthday = i.birthday.trim();
  if (birthday) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(birthday) || Number.isNaN(Date.parse(birthday + "T00:00:00Z"))) return { ok: false, error: "Enter the birthday as a real date." };
    if (new Date(birthday + "T00:00:00Z").toISOString().slice(0, 10) !== birthday) return { ok: false, error: "Enter the birthday as a real date." };
    if (birthday > today) return { ok: false, error: "The birthday cannot be in the future." };
    if (birthday < "1900-01-01") return { ok: false, error: "Enter the birthday as a real date." };
  }
  return { ok: true, name, email: email || null, notes: notes || null, birthday: birthday || null, consent: i.consent };
}

export type RedeemMode = "discount" | "tender";
export const REDEEM_MODES: { key: RedeemMode; label: string }[] = [
  { key: "discount", label: "Discount on the bill (before tax)" },
  { key: "tender", label: "Payment (tax is charged on the full bill)" },
];
export const POINTS_DO_NOT_EXPIRE = "Points do not expire.";
/** Shown beside the redeem setting. The tax adviser must confirm before discount mode is used by a GST restaurant. */
export const REDEEM_TAX_NOTE =
  "Tax note: as a discount, points lower the taxable value of the bill, so GST is charged on the reduced amount. " +
  "That is correct only when the points scheme is known to the guest in advance and the discount is shown on the invoice (GST section 15(3)(a)). " +
  "\"Payment\" is the cautious choice: GST is charged on the full bill. Please confirm with your tax adviser before using the discount mode for a GST restaurant.";

export type LoyaltyRulesInput = { spend: string; value: string; min: string; mode: string; maxPercent: string };

/** Checks the Loyalty rules form. Returns numbers ready to send, or one sentence saying what to fix. */
export function validateLoyaltyRules(i: LoyaltyRulesInput):
  | { ok: true; spend: number; value: number; min: number; mode: RedeemMode; maxPercent: number }
  | { ok: false; error: string } {
  const spend = Number(i.spend);
  if (!(spend > 0) || !Number.isFinite(spend)) return { ok: false, error: "Rupees spent for 1 point must be more than zero." };
  const value = Number(i.value);
  if (!(value >= 0) || !Number.isFinite(value)) return { ok: false, error: "The value of 1 point cannot be negative." };
  const minText = i.min.trim() === "" ? "0" : i.min.trim();
  const min = Number(minText);
  if (!Number.isInteger(min) || min < 0) return { ok: false, error: "Minimum points to redeem must be a whole number, 0 or more." };
  if (i.mode !== "discount" && i.mode !== "tender") return { ok: false, error: "Choose how points are redeemed." };
  const maxPercent = Number(i.maxPercent.trim() === "" ? "100" : i.maxPercent);
  if (!Number.isFinite(maxPercent) || maxPercent < 1 || maxPercent > 100) return { ok: false, error: "The highest share of a bill points can pay must be between 1 and 100." };
  return { ok: true, spend, value, min, mode: i.mode, maxPercent };
}

/** The worked example under the rules form: what a bill earns and what those points are worth. */
export function loyaltyExample(spend: number, value: number): { bill: number; points: number; worth: number } {
  const s = spend > 0 && Number.isFinite(spend) ? spend : 100;
  const v = value >= 0 && Number.isFinite(value) ? value : 1;
  const bill = s * 10;
  const points = Math.floor(bill / s);
  return { bill, points, worth: Math.round(points * v * 100) / 100 };
}
