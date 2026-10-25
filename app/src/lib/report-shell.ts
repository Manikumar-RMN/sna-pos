// Pure helpers behind the report screens: date-range checks for the filter form, link building for the quick
// presets, and total rows for the tables. No React here, so they can be unit tested.

export const REPORT_PRESETS = [
  { key: "today", label: "Today" },
  { key: "yesterday", label: "Yesterday" },
  { key: "7d", label: "Last 7 days" },
  { key: "month", label: "This month" },
  { key: "lastmonth", label: "Last month" },
] as const;

/** True for a real calendar date written YYYY-MM-DD (rejects 2026-02-31). */
export function isRealYmd(s: unknown): s is string {
  if (typeof s !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(s + "T00:00:00Z");
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

/** Checks the From/To dates typed into the filter form. Returns an error in plain words, or null when fine. */
export function validateDateRange(from: string, to: string, max?: string): string | null {
  if (!from && !to) return "Choose a From date and a To date.";
  if (!from) return "Choose a From date.";
  if (!to) return "Choose a To date.";
  if (!isRealYmd(from)) return "The From date is not a valid date.";
  if (!isRealYmd(to)) return "The To date is not a valid date.";
  if (from > to) return "The From date is after the To date.";
  if (max && isRealYmd(max) && to > max) return "The To date is in the future.";
  return null;
}

/** Link for a quick preset. Toggles that are switched on (extra = { name: "1" }) are kept. */
export function presetHref(basePath: string, key: string, extra: Record<string, string> = {}): string {
  const q = new URLSearchParams({ range: key });
  for (const [k, v] of Object.entries(extra)) if (v) q.set(k, v);
  return `${basePath}?${q.toString()}`;
}

/** Adds numbers without floating-point crumbs (0.1 + 0.2 gives 0.3), to 2 decimals. */
export function sumNumbers(values: readonly number[]): number {
  let total = 0;
  for (const v of values) if (Number.isFinite(v)) total += v;
  return Math.round((total + Number.EPSILON) * 100) / 100;
}

/** The sum of one number taken from every row. */
export function sumBy<T>(rows: readonly T[], pick: (row: T) => number): number {
  return sumNumbers(rows.map(pick));
}

/** The largest of one number taken from every row (0 when there are no rows). */
export function maxBy<T>(rows: readonly T[], pick: (row: T) => number): number {
  let m = 0;
  for (const r of rows) {
    const v = pick(r);
    if (Number.isFinite(v) && v > m) m = v;
  }
  return m;
}

/** Total divided by count, rounded to 2 decimals; 0 when the count is 0 (an average bill with no bills). */
export function safeAverage(total: number, count: number): number {
  return count > 0 ? Math.round((total / count + Number.EPSILON) * 100) / 100 : 0;
}

/** "1 Oct 2026 – 25 Oct 2026" style text for the print header; one date when From and To are the same. */
export function rangeText(from: string, to: string, fmt: (ymd: string) => string): string {
  return from === to ? fmt(from) : `${fmt(from)} – ${fmt(to)}`;
}
