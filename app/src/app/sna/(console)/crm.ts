/** Shapes and wording shared by the SNA console's client pages. */

export type ClientRow = {
  id: string;
  client_code: string;
  trading_name: string;
  legal_name: string;
  country_code: string;
  currency: string;
  edition: string;
  status: string;
  signed_up: string;
  is_new: boolean;
  outlets: number;
  monthly: number;
  licence_expiry: string | null;
  days_left: number | null;
  last_contact: string | null;
  next_contact: string | null;
  account_manager: string | null;
  open_requests: number;
  owner_name: string | null;
  owner_email: string | null;
  last_bill: string | null;
};

export type ClientList = {
  today: string;
  counts: Record<"all" | "new" | "expiring" | "expired" | "nolicence" | "followup", number>;
  rows: ClientRow[];
};

export type Contact = { id: string; kind: string; full_name: string; job_title: string | null; phone: string | null; email: string | null };
export type Note = { id: string; kind: string; body: string; created_at: string; by: string | null };
export type Sale = {
  id: string;
  sale_date: string;
  kind: string;
  description: string;
  amount: number;
  currency: string;
  period_from: string | null;
  period_to: string | null;
  invoice_no: string | null;
  paid_on: string | null;
  note: string | null;
  cancelled: boolean;
  cancel_reason: string | null;
  by: string | null;
};

export type Client = {
  id: string;
  today: string;
  client_code: string;
  trading_name: string;
  legal_name: string;
  country_code: string;
  currency: string;
  edition: string;
  status: string;
  signed_up: string;
  monthly: number;
  licence_start: string | null;
  licence_expiry: string | null;
  days_left: number | null;
  account_manager: string | null;
  sales_person: string | null;
  support_person: string | null;
  last_contact: string | null;
  next_contact: string | null;
  owner: { full_name: string; email: string | null; phone: string | null } | null;
  usage: { outlets: number; people: number; last_bill: string | null; bills_30d: number };
  contacts: Contact[];
  notes: Note[];
  sales: Sale[];
  sales_total: number;
  sales_unpaid: number;
  staff: { id: string; full_name: string; role: string }[];
};

export const STATUSES: { key: string; label: string }[] = [
  { key: "trial", label: "Trial" },
  { key: "active", label: "Active" },
  { key: "past_due", label: "Payment overdue" },
  { key: "suspended", label: "Suspended" },
  { key: "cancelled", label: "Cancelled" },
];
export const statusLabel = (s: string) => STATUSES.find((x) => x.key === s)?.label ?? s;

export const CONTACT_KINDS: { key: string; label: string }[] = [
  { key: "owner", label: "Owner" },
  { key: "manager", label: "Manager" },
  { key: "billing", label: "Billing" },
  { key: "accounts", label: "Accounts" },
  { key: "it", label: "IT / systems" },
  { key: "contact", label: "Other contact" },
];
export const NOTE_KINDS: { key: string; label: string }[] = [
  { key: "note", label: "Note" },
  { key: "call", label: "Call" },
  { key: "visit", label: "Visit" },
  { key: "message", label: "WhatsApp / SMS" },
  { key: "email", label: "Email" },
];
export const SALE_KINDS: { key: string; label: string }[] = [
  { key: "new", label: "New licence" },
  { key: "renewal", label: "Renewal" },
  { key: "upgrade", label: "Upgrade" },
  { key: "addon", label: "Add-on" },
  { key: "outlet", label: "Extra outlet" },
  { key: "hardware", label: "Hardware" },
  { key: "service", label: "Service / training" },
  { key: "other", label: "Other" },
];
export const labelOf = (list: { key: string; label: string }[], key: string) => list.find((x) => x.key === key)?.label ?? key;

/** "2026-10-05" → "5 Oct 2026". The same on the server and in the browser. */
export function shortDate(ymd: string | null | undefined): string {
  if (!ymd) return "";
  const d = new Date(`${ymd.slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return ymd;
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
}

/** A date and time in India, where SNA staff work. */
export function indiaDateTime(iso: string): string {
  return new Date(iso).toLocaleString("en-GB", { day: "numeric", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", timeZone: "Asia/Kolkata" });
}

export type Tone = "ok" | "warn" | "bad" | "plain";
export const toneStyle: Record<Tone, { background: string; color: string }> = {
  ok: { background: "var(--color-ok-soft)", color: "var(--color-ok)" },
  warn: { background: "var(--color-warn-soft)", color: "var(--color-warn)" },
  bad: { background: "var(--color-bad-soft)", color: "var(--color-bad)" },
  plain: { background: "var(--color-ground)", color: "var(--color-ink-2)" },
};

/** How to say where a licence stands, from the days left (null = no date set). */
export function licenceState(daysLeft: number | null): { text: string; tone: Tone } {
  if (daysLeft === null || daysLeft === undefined) return { text: "No date set", tone: "plain" };
  if (daysLeft < 0) return { text: `Expired ${-daysLeft} ${daysLeft === -1 ? "day" : "days"} ago`, tone: "bad" };
  if (daysLeft === 0) return { text: "Ends today", tone: "bad" };
  if (daysLeft <= 30) return { text: `${daysLeft} ${daysLeft === 1 ? "day" : "days"} left`, tone: "warn" };
  return { text: `${daysLeft} days left`, tone: "ok" };
}

export function statusTone(status: string): Tone {
  if (status === "active") return "ok";
  if (status === "trial") return "plain";
  if (status === "past_due") return "warn";
  return "bad";
}

/** Friendly words for the lines in a client's history. */
export function eventLabel(event: string): string {
  const map: Record<string, string> = {
    "account.changed": "Licence or status changed",
    "sale.added": "Sale recorded",
    "sale.paid": "Sale marked paid",
    "sale.unpaid": "Sale marked not paid",
    "sale.cancelled": "Sale entry cancelled",
    "edition.changed": "Edition changed",
  };
  return map[event] ?? event;
}
