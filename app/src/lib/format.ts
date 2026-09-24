/** Formatting helpers shared by server and client components. */

export function money(n: number | string | null | undefined, currency = "INR"): string {
  const v = Number(n ?? 0);
  try {
    return new Intl.NumberFormat("en-IN", { style: "currency", currency }).format(v);
  } catch {
    return `${currency} ${v.toFixed(2)}`;
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
  | "refunded"
  | "part-refunded"
  | "paid" {
  if (status === "voided") return "voided";
  if (paymentStatus === "unpaid") return "unpaid";
  if (paymentStatus === "refunded") return "refunded";
  if (paymentStatus === "partially_refunded") return "part-refunded";
  return "paid";
}

export const stateStyle: Record<string, { label: string; bg: string; fg: string }> = {
  paid: { label: "Paid", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  unpaid: { label: "Unpaid", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  voided: { label: "Voided", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
  refunded: { label: "Refunded", bg: "var(--color-ground)", fg: "var(--color-ink-2)" },
  "part-refunded": { label: "Part refunded", bg: "var(--color-ground)", fg: "var(--color-ink-2)" },
};
