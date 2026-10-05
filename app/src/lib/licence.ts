import { cache } from "react";
import { createClient } from "@/lib/supabase/server";

/**
 * Where this restaurant's SNA POS licence stands.
 *   ok     : nothing to show (also when SNA has set no end date).
 *   warn   : 15 days or fewer to the end date; `remind` says whether to show the reminder
 *            (SNA switches it off from its console once payment is in).
 *   locked : the end date has passed, or SNA suspended the account. The restaurant is read-only:
 *            the database refuses new bills, new items and guest QR orders.
 */
export type Licence = {
  state: "ok" | "warn" | "locked";
  reason?: "ended" | "suspended" | "cancelled";
  /** Licence end date, YYYY-MM-DD. */
  ends?: string | null;
  days_left?: number;
  /** The moment read-only starts: 6 a.m. on the day after the end date, restaurant time. */
  lock_at?: string;
  remind?: boolean;
};

const OPEN: Licence = { state: "ok" };

/** One database trip per request, however many screens ask. If it cannot be read, nothing is limited here: the database is the guard. */
export const getLicence = cache(async function getLicence(): Promise<Licence> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("my_licence");
  if (error || !data || typeof data !== "object") return OPEN;
  return data as unknown as Licence;
});

/** "2026-10-05" → "5 Oct 2026". */
export function licenceDate(ymd: string | null | undefined): string {
  if (!ymd) return "";
  const d = new Date(`${ymd.slice(0, 10)}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return ymd;
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
}
