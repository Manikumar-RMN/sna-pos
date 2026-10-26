import { describe, expect, it } from "vitest";
import {
  KOT_DELAYED_MIN,
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
  });
});

describe("classifyTable", () => {
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
    expect(countStates(rows)).toEqual({ free: 2, busy: 1, delayed: 1, kot_delayed: 1, reserved: 1 });
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
  });
  it("drops junk and non-arrays", () => {
    expect(parseFloorRows(null)).toEqual([]);
    expect(parseFloorRows({})).toEqual([]);
    expect(parseFloorRows([null, 3, {}, { table_number: "x" }])).toEqual([]);
  });
});
