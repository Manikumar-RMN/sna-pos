import { describe, expect, it } from "vitest";
import { isRealYmd, maxBy, presetHref, rangeText, safeAverage, sumBy, sumNumbers, validateDateRange } from "../report-shell";

describe("isRealYmd", () => {
  it("accepts real dates and rejects impossible ones", () => {
    expect(isRealYmd("2026-10-25")).toBe(true);
    expect(isRealYmd("2028-02-29")).toBe(true);
    expect(isRealYmd("2026-02-31")).toBe(false);
    expect(isRealYmd("2026-13-01")).toBe(false);
    expect(isRealYmd("25-10-2026")).toBe(false);
    expect(isRealYmd(undefined)).toBe(false);
  });
});

describe("validateDateRange", () => {
  it("passes a good range", () => {
    expect(validateDateRange("2026-10-01", "2026-10-25", "2026-10-25")).toBeNull();
    expect(validateDateRange("2026-10-25", "2026-10-25")).toBeNull();
  });
  it("asks for missing dates", () => {
    expect(validateDateRange("", "")).toMatch(/From date and a To date/);
    expect(validateDateRange("", "2026-10-25")).toBe("Choose a From date.");
    expect(validateDateRange("2026-10-01", "")).toBe("Choose a To date.");
  });
  it("rejects bad, reversed and future dates", () => {
    expect(validateDateRange("2026-02-31", "2026-03-01")).toMatch(/From date is not a valid/);
    expect(validateDateRange("2026-03-01", "2026-02-31")).toMatch(/To date is not a valid/);
    expect(validateDateRange("2026-10-25", "2026-10-01")).toMatch(/after the To date/);
    expect(validateDateRange("2026-10-01", "2026-10-26", "2026-10-25")).toMatch(/future/);
  });
});

describe("presetHref", () => {
  it("builds the link and keeps switched-on toggles", () => {
    expect(presetHref("/reports/x", "7d")).toBe("/reports/x?range=7d");
    expect(presetHref("/reports/x", "today", { pending: "1", nc: "" })).toBe("/reports/x?range=today&pending=1");
  });
});

describe("totals", () => {
  it("sums without floating-point crumbs", () => {
    expect(sumNumbers([0.1, 0.2])).toBe(0.3);
    expect(sumNumbers([])).toBe(0);
    expect(sumNumbers([5, Number.NaN, 7])).toBe(12);
  });
  it("sums and maxes one field of each row", () => {
    const rows = [{ q: 2, a: 10.5, p: 5 }, { q: 3, a: 4.25, p: 12 }];
    expect(sumBy(rows, (r) => r.q)).toBe(5);
    expect(sumBy(rows, (r) => r.a)).toBe(14.75);
    expect(maxBy(rows, (r) => r.p)).toBe(12);
    expect(maxBy([], (r: { p: number }) => r.p)).toBe(0);
  });
  it("averages safely", () => {
    expect(safeAverage(100, 3)).toBe(33.33);
    expect(safeAverage(100, 0)).toBe(0);
  });
});

describe("rangeText", () => {
  it("shows one date or a span", () => {
    const f = (s: string) => `<${s}>`;
    expect(rangeText("2026-10-01", "2026-10-01", f)).toBe("<2026-10-01>");
    expect(rangeText("2026-10-01", "2026-10-02", f)).toBe("<2026-10-01> – <2026-10-02>");
  });
});
