// Pure helpers for scheduled (future-dated) tax rate changes. The database (migration 130) is the authority on every rule here;
// these only let the form say the same thing before a round trip. Dates are plain "YYYY-MM-DD" strings (restaurant-local days).
import type { TaxComponent } from "../actions";

const ISO = /^\d{4}-\d{2}-\d{2}$/;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function parse(iso: string): Date | null {
  if (!ISO.test(iso)) return null;
  const d = new Date(`${iso}T00:00:00Z`);
  return Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== iso ? null : d;
}

/** iso + n days (calendar arithmetic in UTC, so it never depends on the browser's time zone). */
export function addDays(iso: string, n: number): string {
  const d = parse(iso);
  if (!d) throw new Error(`Not a date: ${iso}`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** The first and last day a change can be scheduled for: tomorrow .. one year (366 days) ahead. */
export function scheduleBounds(today: string): { min: string; max: string } {
  return { min: addDays(today, 1), max: addDays(today, 366) };
}

/** null when the date is acceptable; otherwise the sentence to show. Empty means "change now" and is always fine. */
export function checkEffectiveFrom(value: string, today: string): string | null {
  if (value === "") return null;
  if (!parse(value)) return "Choose a valid date.";
  const { min, max } = scheduleBounds(today);
  if (value < min) return "The start date must be after today. To change the rate now, leave the date empty.";
  if (value > max) return "Schedule at most one year ahead.";
  return null;
}

/** 2027-04-01 -> "1 Apr 2027". */
export function friendlyDate(iso: string): string {
  const d = parse(iso);
  return d ? `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}` : iso;
}

export type RateRow = {
  tax_group_id: string;
  valid_from: string;
  valid_to: string | null;
  tax_rate_components: { name: string; rate: number | string; is_compound: boolean; applies_when: string; display_order: number }[] | null;
};

export type PendingRate = { from: string; comps: TaxComponent[] };

const toComps = (rows: RateRow["tax_rate_components"]): TaxComponent[] =>
  [...(rows ?? [])]
    .sort((a, b) => a.display_order - b.display_order)
    .map((c) => ({
      name: c.name,
      rate: Number(c.rate),
      compound: c.is_compound,
      applies_when: (c.applies_when as TaxComponent["applies_when"]) ?? "always",
    }));

/** The rate running today for a group: the newest row that has started and not ended. */
export function currentComps(rates: RateRow[], groupId: string, today: string): TaxComponent[] {
  const r = rates
    .filter((x) => x.tax_group_id === groupId && x.valid_from <= today && (!x.valid_to || x.valid_to >= today))
    .sort((a, b) => (a.valid_from < b.valid_from ? 1 : -1))[0];
  return toComps(r?.tax_rate_components ?? []);
}

/** The change waiting for a future date, if any (the database allows one per group). */
export function pendingRate(rates: RateRow[], groupId: string, today: string): PendingRate | null {
  const r = rates
    .filter((x) => x.tax_group_id === groupId && x.valid_from > today)
    .sort((a, b) => (a.valid_from < b.valid_from ? -1 : 1))[0];
  return r ? { from: r.valid_from, comps: toComps(r.tax_rate_components) } : null;
}
