import { describe, expect, it } from "vitest";
import { buildSummaryEmail, cleanSummary } from "../report-email";

const base = {
  restaurant: "Test One",
  outlet: "Outlet A",
  several_outlets: false,
  currency: "INR",
  business_date: "2026-10-20",
  day_status: "closed",
  bills: 5,
  total_billed: 1090,
  payments: [{ method: "Cash", count: 3, amount: 700 }],
  by_type: [],
  top_items: [],
};

describe("daily summary email: guests and tips", () => {
  it("prints the guests line and the tips line when there are guests and tips", () => {
    const s = cleanSummary({ ...base, covers: 9, sales_per_cover: 87.78, tips: 50, tip_count: 2 });
    expect(s).not.toBeNull();
    const mail = buildSummaryEmail(s!, false);
    expect(mail.text).toContain("Guests: 9 · ");
    expect(mail.text).toContain("per guest");
    expect(mail.text).toContain("Tips (2 tips, not in the total): ");
    expect(mail.html).toContain("Guests");
    expect(mail.html).toContain("Tips (2 tips, not in the total)");
  });
  it("prints neither line when both are zero or missing (an older database)", () => {
    for (const extra of [{}, { covers: 0, sales_per_cover: 0, tips: 0, tip_count: 0 }, { covers: null, tips: "x" }]) {
      const mail = buildSummaryEmail(cleanSummary({ ...base, ...extra })!, false);
      expect(mail.text).not.toContain("Guests");
      expect(mail.text).not.toContain("Tips");
      expect(mail.html).not.toContain("Guests");
    }
  });
  it("prints only the line that has a figure", () => {
    const onlyTips = buildSummaryEmail(cleanSummary({ ...base, tips: 10, tip_count: 1 })!, false);
    expect(onlyTips.text).toContain("Tips (1 tip, not in the total)");
    expect(onlyTips.text).not.toContain("Guests");
    const onlyGuests = buildSummaryEmail(cleanSummary({ ...base, covers: 4 })!, false);
    expect(onlyGuests.text).toContain("Guests: 4");
    expect(onlyGuests.text).not.toContain("per guest");
    expect(onlyGuests.text).not.toContain("Tips");
  });
  it("keeps the existing figures and cleans the new ones", () => {
    const s = cleanSummary({ ...base, covers: -3, tips: -1, tip_count: 2.6 })!;
    expect(s.total_billed).toBe(1090);
    expect(s.covers).toBe(0);
    expect(s.tips).toBe(0);
    expect(s.tip_count).toBe(3);
    expect(buildSummaryEmail(s, false).subject).toContain("5 bills");
  });
});
