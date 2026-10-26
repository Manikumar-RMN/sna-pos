/**
 * Table colours for the floor (the table strip on the order screen and the Captain table grid).
 *
 * The database (public.floor_status, migration 134) reports the facts per table: open bills, since when, kitchen tickets still waiting,
 * the next close reservation, and its own clock. This file turns the facts into one of five states. The thresholds live here only:
 *
 *   delayed      a bill has been open for more than 90 minutes
 *   kot_delayed  a kitchen ticket has been waiting (new or preparing) for more than 15 minutes
 *   busy         an open bill, nothing late
 *   reserved     no open bill and a booking from 60 minutes before to 30 minutes after its time
 *   free         none of the above
 *
 * Pure functions, no React, no clock of their own: the caller passes how long ago the data was fetched.
 */

export const OPEN_DELAYED_MIN = 90;
export const KOT_DELAYED_MIN = 15;
/** A booking shows from this many minutes before its time ... */
export const RESERVE_BEFORE_MIN = 60;
/** ... until this many minutes after it (a late guest still holds the table). */
export const RESERVE_AFTER_MIN = 30;

export type FloorRow = {
  table_id: string;
  table_number: string;
  seats: number | null;
  open_bills: number;
  open_total: number;
  oldest_open_at: string | null;
  kot_waiting: number;
  oldest_kot_at: string | null;
  reservation_id: string | null;
  reservation_at: string | null;
  reservation_name: string | null;
  reservation_party: number | null;
  /** The database's own clock when the row was read. */
  db_now: string;
};

export type TableState = "free" | "busy" | "delayed" | "kot_delayed" | "reserved";

export type TableStatus = {
  state: TableState;
  /** Minutes the oldest open bill has been open (0 when none). */
  openMinutes: number;
  /** Minutes the oldest waiting kitchen ticket has waited (0 when none). */
  kotMinutes: number;
  kotWaiting: number;
  openBills: number;
  /** Minutes until the booking (negative once it is past); null when no booking is near. */
  reservationInMinutes: number | null;
  reservationName: string | null;
  reservationParty: number | null;
  /** A booking is close although the table is not free (shown as a small badge). */
  reservedSoon: boolean;
  /** Short words for the tile, e.g. "95 min open" or "KOT 18 min". */
  note: string;
};

export const STATE_LABEL: Record<TableState, string> = {
  free: "Free",
  busy: "Busy",
  delayed: "Open too long",
  kot_delayed: "Kitchen waiting",
  reserved: "Reserved",
};

/** What each state means, for the small legend under the tables. */
export const STATE_HELP: Record<TableState, string> = {
  free: "No open bill",
  busy: "Has an open bill",
  delayed: `Bill open more than ${OPEN_DELAYED_MIN} min`,
  kot_delayed: `Kitchen ticket waiting more than ${KOT_DELAYED_MIN} min`,
  reserved: "Booked, guests expected",
};

export const STATE_ORDER: TableState[] = ["free", "busy", "delayed", "kot_delayed", "reserved"];

/** Colours as theme tokens that already exist in globals.css (no new variables). */
export const STATE_STYLE: Record<TableState, { borderColor: string; background?: string; borderStyle?: "solid" | "dashed" }> = {
  free: { borderColor: "var(--color-line)" },
  busy: { borderColor: "var(--color-brand)", background: "var(--color-brand-soft)" },
  delayed: { borderColor: "var(--color-bad)", background: "var(--color-bad-soft)" },
  kot_delayed: { borderColor: "var(--color-warn)", background: "var(--color-warn-soft)" },
  reserved: { borderColor: "var(--color-accent-strong)", background: "var(--color-surface-2)", borderStyle: "dashed" },
};

function ms(iso: string | null): number | null {
  if (!iso) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? t : null;
}

/** Whole minutes between two instants, never negative. */
function minutesBetween(fromMs: number, toMs: number): number {
  return Math.max(0, Math.floor((toMs - fromMs) / 60000));
}

/**
 * The state of one table.
 * @param elapsedMs how long ago the row was fetched on this device (0 right after the fetch); the database clock plus this
 *                  gives "now" without trusting the device clock being right.
 */
export function classifyTable(row: FloorRow, elapsedMs = 0): TableStatus {
  const dbNow = ms(row.db_now);
  const now = (dbNow ?? Date.now()) + Math.max(0, elapsedMs);
  const openSince = ms(row.oldest_open_at);
  const kotSince = ms(row.oldest_kot_at);
  const resAt = ms(row.reservation_at);
  const openBills = Math.max(0, Math.floor(Number(row.open_bills) || 0));
  const kotWaiting = Math.max(0, Math.floor(Number(row.kot_waiting) || 0));

  const openMinutes = openBills > 0 && openSince !== null ? minutesBetween(openSince, now) : 0;
  const kotMinutes = kotWaiting > 0 && kotSince !== null ? minutesBetween(kotSince, now) : 0;
  const reservationInMinutes = resAt === null ? null : Math.round((resAt - now) / 60000);
  const inWindow =
    reservationInMinutes !== null && reservationInMinutes <= RESERVE_BEFORE_MIN && reservationInMinutes >= -RESERVE_AFTER_MIN;

  let state: TableState;
  if (openBills > 0) {
    if (openMinutes > OPEN_DELAYED_MIN) state = "delayed";
    else if (kotWaiting > 0 && kotMinutes > KOT_DELAYED_MIN) state = "kot_delayed";
    else state = "busy";
  } else if (inWindow) state = "reserved";
  else state = "free";

  let note = "";
  if (state === "delayed") note = `${openMinutes} min open`;
  else if (state === "kot_delayed") note = `KOT ${kotMinutes} min`;
  else if (state === "busy") note = `${openMinutes} min`;
  else if (state === "reserved") {
    const when = reservationInMinutes ?? 0;
    note = when > 0 ? `in ${when} min` : when === 0 ? "now" : `${-when} min late`;
  }

  return {
    state,
    openMinutes,
    kotMinutes,
    kotWaiting,
    openBills,
    reservationInMinutes: inWindow ? reservationInMinutes : null,
    reservationName: inWindow ? row.reservation_name : null,
    reservationParty: inWindow ? row.reservation_party : null,
    reservedSoon: inWindow && openBills > 0,
    note,
  };
}

/** Counts of tables per state, for the legend. */
export function countStates(rows: FloorRow[], elapsedMs = 0): Record<TableState, number> {
  const out: Record<TableState, number> = { free: 0, busy: 0, delayed: 0, kot_delayed: 0, reserved: 0 };
  for (const r of rows) out[classifyTable(r, elapsedMs).state]++;
  return out;
}

const num = (v: unknown): number => {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : 0;
};
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** Reads what public.floor_status() returned. Anything that is not a row with a table id is left out. */
export function parseFloorRows(data: unknown): FloorRow[] {
  if (!Array.isArray(data)) return [];
  const out: FloorRow[] = [];
  for (const x of data) {
    if (!x || typeof x !== "object") continue;
    const r = x as Record<string, unknown>;
    const id = str(r.table_id);
    if (!id) continue;
    out.push({
      table_id: id,
      table_number: str(r.table_number) ?? "",
      seats: r.seats == null ? null : num(r.seats),
      open_bills: num(r.open_bills),
      open_total: num(r.open_total),
      oldest_open_at: str(r.oldest_open_at),
      kot_waiting: num(r.kot_waiting),
      oldest_kot_at: str(r.oldest_kot_at),
      reservation_id: str(r.reservation_id),
      reservation_at: str(r.reservation_at),
      reservation_name: str(r.reservation_name),
      reservation_party: r.reservation_party == null ? null : num(r.reservation_party),
      db_now: str(r.db_now) ?? new Date().toISOString(),
    });
  }
  return out;
}
