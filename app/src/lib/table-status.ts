/**
 * Table colours for the floor (the table strip on the order screen and the Captain table grid).
 *
 * The database (public.floor_status, migration 134) reports the facts per table: open bills, since when, kitchen tickets still waiting,
 * the next close reservation, and its own clock. This file turns the facts into one of six states. The thresholds live here only:
 *
 *   billed       every open bill has been printed and is waiting for payment (blue). Paying sends the table straight back to free:
 *                there is no "needs cleaning" state (Founder decision, 26 Oct 2026). A printed bill wins over every other colour except
 *                that a booking badge still shows.
 *   delayed      a bill has been open for more than 90 minutes
 *   kot_delayed  a kitchen ticket has been waiting (new or preparing) longer than its prep time plus PREP_GRACE_MIN
 *                (the database sends kot_due_at, migration 142); with no prep time on the ticket, or when the database
 *                does not send kot_due_at (older function), the old fixed 15 minutes apply
 *   busy         an open bill, nothing late: the KOT has been sent and the order is running (red, Founder decision 26 Oct 2026)
 *   reserved     no open bill and a booking from 60 minutes before to 30 minutes after its time
 *   free         none of the above
 *
 * Pure functions, no React, no clock of their own: the caller passes how long ago the data was fetched.
 */

export const OPEN_DELAYED_MIN = 90;
/** The old fixed rule, still used when a ticket has no prep time (or the database sends no kot_due_at). */
export const KOT_DELAYED_MIN = 15;
/**
 * Minutes of grace added to a dish's prep time before the kitchen counts as late.
 * The same number lives in SQL (public.floor_status, migration 142); table-status.test.ts pins this side.
 */
export const PREP_GRACE_MIN = 5;
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
  /** When the first-due waiting ticket becomes late (migration 142). Absent or null: use the fixed 15 minute rule. */
  kot_due_at?: string | null;
  /** The longest prep time (minutes) on that ticket; null when no item has one. */
  kot_prep_min?: number | null;
  /** When that same ticket started waiting. */
  kot_ticket_at?: string | null;
  /** How many open bills have been printed (migration 149). Absent: the database is older, nothing counts as printed. */
  billed_bills?: number;
  /** When the oldest of those prints was logged. */
  billed_at?: string | null;
  reservation_id: string | null;
  reservation_at: string | null;
  reservation_name: string | null;
  reservation_party: number | null;
  /** The database's own clock when the row was read. */
  db_now: string;
};

export type TableState = "free" | "busy" | "billed" | "delayed" | "kot_delayed" | "reserved";

export type TableStatus = {
  state: TableState;
  /** Minutes the oldest open bill has been open (0 when none). */
  openMinutes: number;
  /** Minutes the oldest waiting kitchen ticket has waited (0 when none). */
  kotMinutes: number;
  kotWaiting: number;
  openBills: number;
  /** Minutes since the oldest open bill was printed (0 when none is). */
  billedMinutes: number;
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
  busy: "Order running",
  billed: "Bill printed",
  delayed: "Open too long",
  kot_delayed: "Kitchen waiting",
  reserved: "Reserved",
};

/** What each state means, for the small legend under the tables. */
export const STATE_HELP: Record<TableState, string> = {
  free: "No open bill",
  busy: "KOT sent, order running (red)",
  billed: "Bill printed, waiting for payment",
  delayed: `Bill open more than ${OPEN_DELAYED_MIN} min`,
  kot_delayed: `Kitchen ticket waiting longer than its prep time (${KOT_DELAYED_MIN} min if not set)`,
  reserved: "Booked, guests expected",
};

export const STATE_ORDER: TableState[] = ["free", "busy", "billed", "delayed", "kot_delayed", "reserved"];

export const STATE_STYLE: Record<TableState, { borderColor: string; background?: string; borderStyle?: "solid" | "dashed"; color?: string }> = {
  free: { borderColor: "var(--color-line)" },
  // Solid, dark tiles with white text (founder, 28 Oct 2026): red = KOT sent, blue = bill printed, maroon = open too long.
  busy: { borderColor: "#8F1B14", background: "#B3261E", color: "#FFFFFF" },
  billed: { borderColor: "#0F3A78", background: "#1D4F9F", color: "#FFFFFF" },
  delayed: { borderColor: "#2E0805", background: "#6E120C", color: "#FFFFFF" },
  kot_delayed: { borderColor: "#4F3204", background: "#8A5A00", color: "#FFFFFF" },
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
  const dueAt = ms(row.kot_due_at ?? null);
  // With a due time the figures describe the ticket that is due first; without it, the oldest waiting ticket.
  const kotSince = dueAt !== null ? (ms(row.kot_ticket_at ?? null) ?? ms(row.oldest_kot_at)) : ms(row.oldest_kot_at);
  const prepRaw = row.kot_prep_min == null ? NaN : Number(row.kot_prep_min);
  const kotPrep = dueAt !== null && Number.isFinite(prepRaw) && prepRaw > 0 ? Math.floor(prepRaw) : null;
  const resAt = ms(row.reservation_at);
  const openBills = Math.max(0, Math.floor(Number(row.open_bills) || 0));
  const kotWaiting = Math.max(0, Math.floor(Number(row.kot_waiting) || 0));

  const billedBills = Math.max(0, Math.floor(Number(row.billed_bills) || 0));
  const billedSince = ms(row.billed_at ?? null);
  const billedMinutes = billedBills > 0 && billedSince !== null ? minutesBetween(billedSince, now) : 0;

  const openMinutes = openBills > 0 && openSince !== null ? minutesBetween(openSince, now) : 0;
  const kotMinutes = kotWaiting > 0 && kotSince !== null ? minutesBetween(kotSince, now) : 0;
  const reservationInMinutes = resAt === null ? null : Math.round((resAt - now) / 60000);
  const inWindow =
    reservationInMinutes !== null && reservationInMinutes <= RESERVE_BEFORE_MIN && reservationInMinutes >= -RESERVE_AFTER_MIN;

  let state: TableState;
  if (openBills > 0) {
    if (billedBills >= openBills) state = "billed";
    else if (openMinutes > OPEN_DELAYED_MIN) state = "delayed";
    else if (kotWaiting > 0 && (dueAt !== null ? now > dueAt : kotMinutes > KOT_DELAYED_MIN)) state = "kot_delayed";
    else state = "busy";
  } else if (inWindow) state = "reserved";
  else state = "free";

  let note = "";
  if (state === "billed") note = billedMinutes > 0 ? `printed ${billedMinutes} min ago` : "printed";
  else if (state === "delayed") note = `${openMinutes} min open`;
  else if (state === "kot_delayed") note = kotPrep !== null ? `KOT ${kotMinutes} min, prep ${kotPrep}` : `KOT ${kotMinutes} min`;
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
    billedMinutes,
    reservationInMinutes: inWindow ? reservationInMinutes : null,
    reservationName: inWindow ? row.reservation_name : null,
    reservationParty: inWindow ? row.reservation_party : null,
    reservedSoon: inWindow && openBills > 0,
    note,
  };
}

/** Counts of tables per state, for the legend. */
export function countStates(rows: FloorRow[], elapsedMs = 0): Record<TableState, number> {
  const out: Record<TableState, number> = { free: 0, busy: 0, billed: 0, delayed: 0, kot_delayed: 0, reserved: 0 };
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
      kot_due_at: str(r.kot_due_at),
      kot_prep_min: r.kot_prep_min == null ? null : num(r.kot_prep_min),
      kot_ticket_at: str(r.kot_ticket_at),
      billed_bills: num(r.billed_bills),
      billed_at: str(r.billed_at),
      reservation_id: str(r.reservation_id),
      reservation_at: str(r.reservation_at),
      reservation_name: str(r.reservation_name),
      reservation_party: r.reservation_party == null ? null : num(r.reservation_party),
      db_now: str(r.db_now) ?? new Date().toISOString(),
    });
  }
  return out;
}
