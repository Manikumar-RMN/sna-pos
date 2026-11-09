import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  KOT_DELAYED_MIN,
  PREP_GRACE_MIN,
  OPEN_DELAYED_MIN,
  RESERVE_AFTER_MIN,
  RESERVE_BEFORE_MIN,
  classifyTable,
  countStates,
  parseFloorRows,
  type FloorRow,
} from "../table-status";

const NOW = "2026-10-25T12:00:00.000Z";
const at = (minutesFromNow: number) => new Date(Date.parse(NOW) + minutesFromNow * 60000).toISOString();
const row = (over: Partial<FloorRow> = {}): FloorRow => ({
  table_id: "t1",
  table_number: "T1",
  seats: 4,
  open_bills: 0,
  open_total: 0,
  oldest_open_at: null,
  kot_waiting: 0,
  oldest_kot_at: null,
  reservation_id: null,
  reservation_at: null,
  reservation_name: null,
  reservation_party: null,
  db_now: NOW,
  ...over,
});

describe("thresholds", () => {
  it("are the agreed ones", () => {
    expect(OPEN_DELAYED_MIN).toBe(90);
    expect(KOT_DELAYED_MIN).toBe(15);
    expect(RESERVE_BEFORE_MIN).toBe(60);
    expect(RESERVE_AFTER_MIN).toBe(30);
    expect(PREP_GRACE_MIN).toBe(5);
  });
  it("agrees with the grace written in migration 142 (skipped while that file is not in this checkout)", () => {
    const file = join(process.cwd(), "..", "supabase", "migrations", "142_floor_status_prep.sql");
    if (!existsSync(file)) return;
    const sql = readFileSync(file, "utf8");
    expect(sql).toMatch(new RegExp(`\\b${PREP_GRACE_MIN}\\b`));
  });
});

describe("classifyTable", () => {
  it("is billed (blue) when every open bill has been printed, even when the bill is old or the kitchen is late", () => {
    const base = { open_bills: 1, oldest_open_at: at(-30), billed_bills: 1, billed_at: at(-5) };
    const s = classifyTable(row(base));
    expect(s.state).toBe("billed");
    expect(s.billedMinutes).toBe(5);
    expect(s.note).toBe("printed 5 min ago");
    expect(classifyTable(row({ ...base, oldest_open_at: at(-200) })).state).toBe("billed");
    expect(classifyTable(row({ ...base, kot_waiting: 1, oldest_kot_at: at(-40) })).state).toBe("billed");
  });
  it("is not billed when only some of the open bills were printed, or when the database sends no print count", () => {
    expect(classifyTable(row({ open_bills: 2, oldest_open_at: at(-30), billed_bills: 1, billed_at: at(-5) })).state).toBe("busy");
    expect(classifyTable(row({ open_bills: 1, oldest_open_at: at(-30) })).state).toBe("busy");
  });
  it("goes straight back to free once nothing is open (paid), whatever was printed before", () => {
    expect(classifyTable(row({ open_bills: 0, billed_bills: 0 })).state).toBe("free");
  });
  it("reads the print columns from the database rows", () => {
    const [r] = parseFloorRows([{ table_id: "x", table_number: "1", billed_bills: 2, billed_at: at(-3) }]);
    expect(r.billed_bills).toBe(2);
    expect(r.billed_at).toBe(at(-3));
  });
  it("is free with no bill and no booking", () => {
    expect(classifyTable(row()).state).toBe("free");
  });
  it("is busy with an open bill that is not late", () => {
    const s = classifyTable(row({ open_bills: 1, open_total: 300, oldest_open_at: at(-30) }));
    expect(s.state).toBe("busy");
    expect(s.openMinutes).toBe(30);
    expect(s.note).toBe("30 min");
  });
  it("is delayed only after MORE than 90 minutes open", () => {
    expect(classifyTable(row({ open_bills: 1, oldest_open_at: at(-90) })).state).toBe("busy");
    expect(classifyTable(row({ open_bills: 1, oldest_open_at: at(-91) })).state).toBe("delayed");
  });
  it("is kot_delayed only after MORE than 15 minutes of a waiting ticket", () => {
    const base = { open_bills: 1, oldest_open_at: at(-20), kot_waiting: 2 };
    expect(classifyTable(row({ ...base, oldest_kot_at: at(-15) })).state).toBe("busy");
    const late = classifyTable(row({ ...base, oldest_kot_at: at(-16) }));
    expect(late.state).toBe("kot_delayed");
    expect(late.note).toBe("KOT 16 min");
    expect(late.kotWaiting).toBe(2);
  });
  it("a late bill wins over a late kitchen ticket", () => {
    expect(classifyTable(row({ open_bills: 1, oldest_open_at: at(-120), kot_waiting: 1, oldest_kot_at: at(-30) })).state).toBe("delayed");
  });
  it("ignores a kitchen time when no ticket is waiting", () => {
    expect(classifyTable(row({ open_bills: 1, oldest_open_at: at(-20), kot_waiting: 0, oldest_kot_at: at(-60) })).state).toBe("busy");
  });
  it("is reserved from 60 minutes before to 30 minutes after the booking", () => {
    expect(classifyTable(row({ reservation_at: at(61), reservation_name: "Rita" })).state).toBe("free");
    expect(classifyTable(row({ reservation_at: at(60), reservation_name: "Rita" })).state).toBe("reserved");
    expect(classifyTable(row({ reservation_at: at(0) })).state).toBe("reserved");
    expect(classifyTable(row({ reservation_at: at(-30) })).state).toBe("reserved");
    expect(classifyTable(row({ reservation_at: at(-31) })).state).toBe("free");
  });
  it("describes the booking", () => {
    const s = classifyTable(row({ reservation_at: at(45), reservation_name: "Rita", reservation_party: 4 }));
    expect(s.reservationInMinutes).toBe(45);
    expect(s.reservationName).toBe("Rita");
    expect(s.reservationParty).toBe(4);
    expect(s.note).toBe("in 45 min");
    expect(classifyTable(row({ reservation_at: at(-10) })).note).toBe("10 min late");
    expect(classifyTable(row({ reservation_at: at(0) })).note).toBe("now");
  });
  it("an open bill beats a booking; the booking is only a badge", () => {
    const s = classifyTable(row({ open_bills: 1, oldest_open_at: at(-10), reservation_at: at(20), reservation_name: "Sam" }));
    expect(s.state).toBe("busy");
    expect(s.reservedSoon).toBe(true);
  });
  it("uses the database clock plus the time since the fetch, not the device clock", () => {
    const r = row({ open_bills: 1, oldest_open_at: at(-85) });
    expect(classifyTable(r, 0).state).toBe("busy");
    expect(classifyTable(r, 6 * 60000).state).toBe("delayed"); // six minutes later on this screen
    expect(classifyTable(r, -5000).openMinutes).toBe(85); // a negative elapsed time is ignored
  });
  it("never shows negative minutes (clock skew)", () => {
    expect(classifyTable(row({ open_bills: 1, oldest_open_at: at(5) })).openMinutes).toBe(0);
  });
  it("copes with bad dates", () => {
    const s = classifyTable(row({ open_bills: 1, oldest_open_at: "not a date", reservation_at: "x", db_now: "y" }));
    expect(s.state).toBe("busy");
    expect(s.reservationInMinutes).toBeNull();
  });
});

describe("classifyTable with a prep time (migration 142)", () => {
  // A ticket that started 11 min ago, prep 5 -> due 10 min after its start.
  const base = { open_bills: 1, oldest_open_at: at(-20), kot_waiting: 1 };
  const due = (startMin: number, prep: number | null) => ({
    oldest_kot_at: at(startMin),
    kot_ticket_at: at(startMin),
    kot_prep_min: prep,
    kot_due_at: at(startMin + (prep ?? 0) + PREP_GRACE_MIN),
  });
  it("is late only after prep plus grace", () => {
    expect(classifyTable(row({ ...base, ...due(-10, 5) })).state).toBe("busy"); // exactly due
    const late = classifyTable(row({ ...base, ...due(-11, 5) }));
    expect(late.state).toBe("kot_delayed");
    expect(late.note).toBe("KOT 11 min, prep 5");
  });
  it("a long prep keeps the table calm past 15 minutes", () => {
    expect(classifyTable(row({ ...base, ...due(-20, 30) })).state).toBe("busy");
  });
  it("a ticket with no prep time uses the 15 minute rule (due = start + 15)", () => {
    const d = { oldest_kot_at: at(-16), kot_ticket_at: at(-16), kot_prep_min: null, kot_due_at: at(-1) };
    const s = classifyTable(row({ ...base, ...d }));
    expect(s.state).toBe("kot_delayed");
    expect(s.note).toBe("KOT 16 min");
  });
  it("describes the ticket that is due first, not the oldest one", () => {
    const s = classifyTable(row({ ...base, oldest_kot_at: at(-40), kot_ticket_at: at(-12), kot_prep_min: 5, kot_due_at: at(-2) }));
    expect(s.state).toBe("kot_delayed");
    expect(s.kotMinutes).toBe(12);
  });
  it("falls back to the fixed 15 minutes when the new columns are missing or null", () => {
    expect(classifyTable(row({ ...base, oldest_kot_at: at(-15) })).state).toBe("busy");
    expect(classifyTable(row({ ...base, oldest_kot_at: at(-16), kot_due_at: null, kot_prep_min: null })).state).toBe("kot_delayed");
  });
  it("ignores a bad due time and uses the fixed rule", () => {
    expect(classifyTable(row({ ...base, oldest_kot_at: at(-16), kot_due_at: "junk" })).state).toBe("kot_delayed");
  });
  it("moves with the time since the fetch", () => {
    const r = row({ ...base, ...due(-5, 5) });
    expect(classifyTable(r, 0).state).toBe("busy");
    expect(classifyTable(r, 6 * 60000).state).toBe("kot_delayed");
  });
  it("a late bill still wins; no waiting ticket ignores kot_due_at", () => {
    expect(classifyTable(row({ open_bills: 1, oldest_open_at: at(-120), kot_waiting: 1, ...due(-30, 5) })).state).toBe("delayed");
    expect(classifyTable(row({ ...base, kot_waiting: 0, ...due(-30, 5) })).state).toBe("busy");
  });
});

describe("countStates", () => {
  it("counts each state", () => {
    const rows = [
      row({ table_id: "a" }),
      row({ table_id: "b", open_bills: 1, oldest_open_at: at(-5) }),
      row({ table_id: "c", open_bills: 1, oldest_open_at: at(-100) }),
      row({ table_id: "d", open_bills: 1, oldest_open_at: at(-30), kot_waiting: 1, oldest_kot_at: at(-20) }),
      row({ table_id: "e", reservation_at: at(10) }),
      row({ table_id: "f" }),
    ];
    expect(countStates(rows)).toEqual({ free: 2, busy: 1, billed: 0, delayed: 1, kot_delayed: 1, reserved: 1 });
  });
});

describe("parseFloorRows", () => {
  it("reads a database answer, turning number strings into numbers", () => {
    const rows = parseFloorRows([
      {
        table_id: "t1", table_number: "T1", seats: 4, open_bills: "2", open_total: "726.00", oldest_open_at: at(-5), kot_waiting: 1, oldest_kot_at: at(-2),
        reservation_id: null, reservation_at: null, reservation_name: null, reservation_party: null, db_now: NOW,
      },
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0].open_bills).toBe(2);
    expect(rows[0].open_total).toBe(726);
    expect(rows[0].reservation_id).toBeNull();
    expect(rows[0].kot_due_at).toBeNull(); // old function: no prep columns
    expect(rows[0].kot_prep_min).toBeNull();
  });
  it("reads the prep columns when the database sends them", () => {
    const [r] = parseFloorRows([{ table_id: "t1", kot_due_at: at(3), kot_prep_min: "12", kot_ticket_at: at(-9) }]);
    expect(r.kot_due_at).toBe(at(3));
    expect(r.kot_prep_min).toBe(12);
    expect(r.kot_ticket_at).toBe(at(-9));
  });
  it("drops junk and non-arrays", () => {
    expect(parseFloorRows(null)).toEqual([]);
    expect(parseFloorRows({})).toEqual([]);
    expect(parseFloorRows([null, 3, {}, { table_number: "x" }])).toEqual([]);
  });
});

describe("open_items (migration 188)", () => {
  it("is read as a number, and 0 when the database is older", () => {
    const [a] = parseFloorRows([{ table_id: "x", table_number: "1", open_items: 5 }]);
    const [b] = parseFloorRows([{ table_id: "y", table_number: "2" }]);
    expect(a.open_items).toBe(5);
    expect(b.open_items).toBe(0);
  });
});
