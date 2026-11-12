/** Formatting helpers shared by server and client components. */

/** Currencies with no minor unit in everyday use. */
const ZERO_DECIMAL = new Set(["IDR", "JPY", "KRW", "VND"]);
/** English formatting per currency; only India uses lakh grouping. */
const LOCALE: Record<string, string> = {
  INR: "en-IN",
  AED: "en-AE",
  SGD: "en-SG",
  MYR: "en-MY",
  THB: "en-US",
  IDR: "en-US",
  PHP: "en-PH",
};

export function money(n: number | string | null | undefined, currency = "INR"): string {
  let v = Number(n ?? 0);
  const digits = ZERO_DECIMAL.has(currency) ? 0 : 2;
  // A tiny negative (or -0) would print as "-₹0.00"; show it as plain zero.
  if (Math.abs(v) < 0.5 * 10 ** -digits) v = 0;
  try {
    return new Intl.NumberFormat(LOCALE[currency] ?? "en-US", {
      style: "currency",
      currency,
      minimumFractionDigits: digits,
      maximumFractionDigits: digits,
    }).format(v);
  } catch {
    return `${currency} ${v.toFixed(digits)}`;
  }
}

/** Cash rounding exactly as the database applies it (app.round_cash). */
export function roundCash(amount: number, mode: string): number {
  const cents = Math.round(amount * 100);
  switch (mode) {
    case "nearest_1":
      return Math.round(cents / 100);
    case "nearest_0_05":
      return (Math.round(cents / 5) * 5) / 100;
    case "nearest_0_10":
      return (Math.round(cents / 10) * 10) / 100;
    default:
      return cents / 100;
  }
}

export function isYmd(s: unknown): s is string {
  return typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);
}

/** Today's date (YYYY-MM-DD) in the restaurant's timezone. */
export function todayIn(tz: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: tz,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

export function addDays(ymd: string, days: number): string {
  const d = new Date(ymd + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

function tzOffsetMs(date: Date, tz: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date);
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? 0);
  const asUtc = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
  return asUtc - date.getTime();
}

/** The UTC instant at which a local calendar day starts in `tz`. */
export function localDayStartIso(ymd: string, tz: string): string {
  const [y, m, d] = ymd.split("-").map(Number);
  const guess = new Date(Date.UTC(y, m - 1, d));
  return new Date(guess.getTime() - tzOffsetMs(guess, tz)).toISOString();
}

export function dateTime(iso: string | null | undefined, tz: string): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("en-IN", {
    timeZone: tz,
    day: "2-digit",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function timeOnly(iso: string | null | undefined, tz: string): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleTimeString("en-IN", { timeZone: tz, hour: "2-digit", minute: "2-digit" });
}

export function longDate(ymd: string): string {
  return new Date(ymd + "T00:00:00Z").toLocaleDateString("en-IN", {
    timeZone: "UTC",
    weekday: "short",
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

export const orderTypeLabel: Record<string, string> = {
  dine_in: "Dine-in",
  takeaway: "Takeaway",
  delivery: "Delivery",
};

/** One word describing where a bill stands, used for badges. */
export function billState(status: string, paymentStatus: string):
  | "voided"
  | "unpaid"
  | "part-paid"
  | "refunded"
  | "part-refunded"
  | "paid" {
  if (status === "voided") return "voided";
  if (paymentStatus === "unpaid") return "unpaid";
  if (paymentStatus === "partial") return "part-paid";
  if (paymentStatus === "refunded") return "refunded";
  if (paymentStatus === "partially_refunded") return "part-refunded";
  return "paid";
}

export const stateStyle: Record<string, { label: string; bg: string; fg: string }> = {
  paid: { label: "Paid", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  unpaid: { label: "Unpaid", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  "part-paid": { label: "Part paid", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  voided: { label: "Voided", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
  refunded: { label: "Refunded", bg: "var(--color-ground)", fg: "var(--color-ink-2)" },
  "part-refunded": { label: "Part refunded", bg: "var(--color-ground)", fg: "var(--color-ink-2)" },
};

/** "YYYY-MM-DDTHH:mm" for a datetime-local field, showing a moment as the wall clock of `tz`. */
export function toZonedInput(iso: string | null | undefined, tz: string): string {
  if (!iso) return "";
  const p = new Intl.DateTimeFormat("en-CA", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date(iso));
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? "00";
  return `${g("year")}-${g("month")}-${g("day")}T${g("hour")}:${g("minute")}`;
}

/** The moment (ISO) that the wall clock `value` ("YYYY-MM-DDTHH:mm") shows in `tz`. */
export function fromZonedInput(value: string, tz: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(value);
  if (!m) return new Date(value).toISOString();
  const guess = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]));
  let t = guess.getTime() - tzOffsetMs(guess, tz);
  t = guess.getTime() - tzOffsetMs(new Date(t), tz); // once more, in case a clock change sits between
  return new Date(t).toISOString();
}
