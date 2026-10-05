import { isYmd, longDate, money, orderTypeLabel } from "./format";

/**
 * The daily summary email: the figures the database sends (app.report_summary)
 * turned into a subject, a plain-text body and an HTML body.
 *
 * Everything that came from a restaurant (its name, dish names, payment method
 * names) is treated as untrusted text: cut to a sensible length and escaped
 * before it goes into HTML.
 */
export type ReportSummary = {
  restaurant: string;
  outlet: string;
  several_outlets: boolean;
  currency: string;
  business_date: string;
  /** "open", "closed", "parked" or "none" (no bills were made that day). */
  day_status: string;
  /** An older day that was never closed, so it holds every bill made since. */
  lagging: boolean;
  /** The day's own end time has passed. */
  ended: boolean;
  bills: number;
  total_billed: number;
  discounts: number;
  tax: number;
  service_charge: number;
  voided_bills: number;
  voided_value: number;
  unpaid_bills: number;
  unpaid_amount: number;
  refunds: number;
  refund_count: number;
  payments: { method: string; count: number; amount: number }[];
  by_type: { type: string; bills: number; total: number }[];
  top_items: { item: string; qty: number; amount: number }[];
};

const num = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
};
const text = (v: unknown, max: number): string =>
  String(v ?? "")
    // No line breaks or other control characters: these values also go into the subject line.
    .replace(/[\u0000-\u001f\u007f]+/g, " ")
    // No web links: a name is a name, and this email goes to people outside the restaurant.
    .replace(/(?:https?:\/\/|www\.)\S*/gi, " ")
    .replace(/\s{2,}/g, " ")
    .trim()
    .slice(0, max);
const list = (v: unknown, max: number): Record<string, unknown>[] =>
  Array.isArray(v) ? (v.filter((x) => x && typeof x === "object") as Record<string, unknown>[]).slice(0, max) : [];

/** Keeps only what the email needs, with safe types. Null when the essentials are missing. */
export function cleanSummary(raw: unknown): ReportSummary | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const restaurant = text(r.restaurant, 80);
  // Checked whole, not cut to length: "rupees" must not pass as "RUP".
  const currency = typeof r.currency === "string" ? r.currency.trim().toUpperCase() : "";
  if (!restaurant || !/^[A-Z]{3}$/.test(currency) || !isYmd(r.business_date)) return null;
  return {
    restaurant,
    outlet: text(r.outlet, 60),
    several_outlets: r.several_outlets === true,
    currency,
    business_date: r.business_date,
    day_status: text(r.day_status, 10),
    lagging: r.lagging === true,
    ended: r.ended === true,
    bills: num(r.bills),
    total_billed: num(r.total_billed),
    discounts: num(r.discounts),
    tax: num(r.tax),
    service_charge: num(r.service_charge),
    voided_bills: num(r.voided_bills),
    voided_value: num(r.voided_value),
    unpaid_bills: num(r.unpaid_bills),
    unpaid_amount: num(r.unpaid_amount),
    refunds: num(r.refunds),
    refund_count: num(r.refund_count),
    payments: list(r.payments, 12).map((p) => ({ method: text(p.method, 40), count: num(p.count), amount: num(p.amount) })),
    by_type: list(r.by_type, 6).map((t) => ({ type: text(t.type, 20), bills: num(t.bills), total: num(t.total) })),
    top_items: list(r.top_items, 5).map((i) => ({ item: text(i.item, 60), qty: num(i.qty), amount: num(i.amount) })),
  };
}

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
/** 2 stays "2", 1.5 stays "1.5": quantities are not money. */
const qty = (n: number) => String(Math.round(n * 1000) / 1000);

export function buildSummaryEmail(s: ReportSummary, test: boolean): { subject: string; text: string; html: string } {
  const m = (n: number) => money(n, s.currency);
  const place = s.several_outlets && s.outlet ? `${s.restaurant} · ${s.outlet}` : s.restaurant;
  const day = longDate(s.business_date);
  const received = s.payments.reduce((a, p) => a + p.amount, 0);
  const nothing = s.bills === 0 && s.voided_bills === 0;

  const state =
    s.day_status === "closed"
      ? "The day is closed: these are the final figures."
      : nothing
        ? "No bills were made on this day."
        : s.lagging
          ? "This day has not been closed yet, so it holds every bill made since then. Close the day in SNA POS to start a fresh one."
          : s.ended
            ? "These are the figures for the whole day."
            : "The day was still open when this was sent, so these are the figures up to then.";

  const subject = `${test ? "[Test] " : ""}${place}: ${day} – ${nothing ? "no bills" : `${plural(s.bills, "bill", "bills")}, ${m(s.total_billed)}`}`.slice(0, 200);

  // Rows of "label … value" used by both bodies.
  const headline: [string, string][] = [
    ["Total billed", m(s.total_billed)],
    ["Bills", String(s.bills)],
    // Payments taken on this day's bills (not reduced by refunds, which are listed below).
    ["Received for these bills", m(received)],
  ];
  if (s.unpaid_amount > 0) headline.push([`Not yet paid (${plural(s.unpaid_bills, "bill", "bills")})`, m(s.unpaid_amount)]);

  const pay: [string, string][] = s.payments.map((p) => [`${p.method} (${p.count})`, m(p.amount)]);
  const types: [string, string][] = s.by_type.map((t) => [`${Object.prototype.hasOwnProperty.call(orderTypeLabel, t.type) ? orderTypeLabel[t.type] : t.type} (${plural(t.bills, "bill", "bills")})`, m(t.total)]);
  const dishes: [string, string][] = s.top_items.map((i) => [`${i.item} × ${qty(i.qty)}`, m(i.amount)]);
  const other: [string, string][] = [];
  if (s.discounts > 0) other.push(["Discounts given", m(s.discounts)]);
  if (s.service_charge > 0) other.push(["Service charge", m(s.service_charge)]);
  if (s.tax > 0) other.push(["Tax", m(s.tax)]);
  if (s.voided_bills > 0) other.push([`Voided (${plural(s.voided_bills, "bill", "bills")})`, m(s.voided_value)]);
  if (s.refund_count > 0) other.push([`Refunds (${s.refund_count})`, m(s.refunds)]);

  const sections: [string, [string, string][]][] = [
    ["", headline],
    ["Received by", pay],
    ["Order types", types],
    ["Top dishes", dishes],
    ["Also", other],
  ].filter(([, rows]) => (rows as [string, string][]).length > 0) as [string, [string, string][]][];

  const footer = `Sent by SNA POS because ${s.restaurant} set up a daily summary for this address. To stop it, ask the owner to remove your address in Settings → Daily summary.`;
  const testNote = "This is a test sent from Settings → Daily summary.";

  const lines: string[] = [`Daily summary – ${place}`, day, state];
  if (test) lines.push(testNote);
  for (const [title, rows] of nothing ? [] : sections) {
    lines.push("");
    if (title) lines.push(`${title}:`);
    for (const [k, v] of rows) lines.push(`${title ? "  " : ""}${k}: ${v}`);
  }
  lines.push("", footer);

  const e = escapeHtml;
  const ink = "#221A12";
  const soft = "#6B5E4E";
  const line = "#EADFCB";
  const row = ([k, v]: [string, string], strong: boolean) =>
    `<tr><td style="padding:6px 0;color:${ink};${strong ? "font-weight:bold;" : ""}">${e(k)}</td>` +
    `<td align="right" style="padding:6px 0;color:${ink};white-space:nowrap;${strong ? "font-weight:bold;" : ""}">${e(v)}</td></tr>`;
  const block = ([title, rows]: [string, [string, string][]]) =>
    (title
      ? `<tr><td colspan="2" style="padding:16px 0 4px;border-top:1px solid ${line};color:${soft};font-size:12px;font-weight:bold;text-transform:uppercase;letter-spacing:.04em;">${e(title)}</td></tr>`
      : "") + rows.map((r) => row(r, !title)).join("");

  const html =
    `<!doctype html><html><body style="margin:0;padding:0;background:#FBF6EC;">` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#FBF6EC;"><tr><td align="center" style="padding:20px 12px;">` +
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#FFFFFF;border:1px solid ${line};border-radius:14px;font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.4;">` +
    `<tr><td style="padding:18px 20px;background:#1E4D2B;border-radius:14px 14px 0 0;color:#FFFFFF;">` +
    `<div style="font-size:12px;opacity:.85;">Daily summary</div>` +
    `<div style="font-size:19px;font-weight:bold;">${e(place)}</div>` +
    `<div style="font-size:14px;opacity:.9;">${e(day)}</div></td></tr>` +
    `<tr><td style="padding:14px 20px 4px;color:${soft};font-size:13px;">${e(state)}${test ? `<br><b>${e(testNote)}</b>` : ""}</td></tr>` +
    (nothing
      ? ""
      : `<tr><td style="padding:4px 20px 8px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0">${sections.map(block).join("")}</table></td></tr>`) +
    `<tr><td style="padding:14px 20px 18px;border-top:1px solid ${line};color:${soft};font-size:12px;">${e(footer)}</td></tr>` +
    `</table></td></tr></table></body></html>`;

  return { subject, text: lines.join("\n"), html };
}

/** One address, lower-cased, or null. The same rule the database uses. */
export function cleanEmail(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const e = v.trim().toLowerCase();
  return e.length <= 254 && /^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$/.test(e) ? e : null;
}
