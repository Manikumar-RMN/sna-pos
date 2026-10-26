import { describe, expect, it } from "vitest";
import { addDays, checkEffectiveFrom, currentComps, friendlyDate, pendingRate, scheduleBounds, type RateRow } from "./schedule";

const comp = (name: string, rate: number, order = 1) => ({ name, rate, is_compound: false, applies_when: "always", display_order: order });
const rates: RateRow[] = [
  { tax_group_id: "g1", valid_from: "2020-01-01", valid_to: "2026-12-31", tax_rate_components: [comp("CGST", 2.5), comp("SGST", 2.5, 2)] },
  { tax_group_id: "g1", valid_from: "2027-01-01", valid_to: null, tax_rate_components: [comp("CGST", 6), comp("SGST", 6, 2)] },
  { tax_group_id: "g2", valid_from: "2020-01-01", valid_to: null, tax_rate_components: [comp("VAT", 7)] },
];

describe("addDays / scheduleBounds", () => {
  it("does calendar arithmetic across month and year ends and leap days", () => {
    expect(addDays("2026-12-31", 1)).toBe("2027-01-01");
    expect(addDays("2028-02-28", 1)).toBe("2028-02-29");
    expect(addDays("2027-03-01", -1)).toBe("2027-02-28");
  });
  it("rejects a non-date", () => {
    expect(() => addDays("2027-02-30", 1)).toThrow();
  });
  it("allows tomorrow .. 366 days ahead", () => {
    expect(scheduleBounds("2026-10-25")).toEqual({ min: "2026-10-26", max: "2027-10-26" });
  });
});

describe("checkEffectiveFrom", () => {
  const today = "2026-10-25";
  it("empty means change now", () => expect(checkEffectiveFrom("", today)).toBeNull());
  it("accepts tomorrow and the last allowed day", () => {
    expect(checkEffectiveFrom("2026-10-26", today)).toBeNull();
    expect(checkEffectiveFrom("2027-10-26", today)).toBeNull();
  });
  it("refuses today, the past, too far ahead and junk", () => {
    expect(checkEffectiveFrom("2026-10-25", today)).toMatch(/after today/);
    expect(checkEffectiveFrom("2026-01-01", today)).toMatch(/after today/);
    expect(checkEffectiveFrom("2027-10-27", today)).toMatch(/one year/);
    expect(checkEffectiveFrom("25/10/2026", today)).toMatch(/valid date/);
  });
});

describe("friendlyDate", () => {
  it("formats without depending on the time zone", () => {
    expect(friendlyDate("2027-04-01")).toBe("1 Apr 2027");
    expect(friendlyDate("2026-12-31")).toBe("31 Dec 2026");
    expect(friendlyDate("garbage")).toBe("garbage");
  });
});

describe("currentComps / pendingRate", () => {
  it("shows the running rate, not the pending one", () => {
    expect(currentComps(rates, "g1", "2026-10-25").map((c) => c.rate)).toEqual([2.5, 2.5]);
    expect(currentComps(rates, "g1", "2027-01-01").map((c) => c.rate)).toEqual([6, 6]);
  });
  it("finds the pending change for a group only", () => {
    expect(pendingRate(rates, "g1", "2026-10-25")).toEqual({
      from: "2027-01-01",
      comps: [
        { name: "CGST", rate: 6, compound: false, applies_when: "always" },
        { name: "SGST", rate: 6, compound: false, applies_when: "always" },
      ],
    });
    expect(pendingRate(rates, "g2", "2026-10-25")).toBeNull();
    expect(pendingRate(rates, "g1", "2027-01-01")).toBeNull();
  });
  it("coerces numeric strings from the database", () => {
    const r: RateRow[] = [{ tax_group_id: "g", valid_from: "2020-01-01", valid_to: null, tax_rate_components: [{ ...comp("X", 0), rate: "12.500" }] }];
    expect(currentComps(r, "g", "2026-01-01")[0].rate).toBe(12.5);
  });
});
