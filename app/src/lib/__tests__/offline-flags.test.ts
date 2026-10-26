import { describe, expect, it } from "vitest";
import { describeOfflineFlags } from "../offline-flags";

describe("describeOfflineFlags", () => {
  it("says what happened, in words", () => {
    const t = describeOfflineFlags([
      { flag: "price_corrected", item: "Masala Dosa", offline_price: 1, menu_price: 120 },
      { flag: "discount_removed", amount: 100 },
      { flag: "method_unknown" },
      { flag: "total_differs", printed: 1, recorded: 252 },
      { flag: "device_clock_ahead" },
    ]);
    expect(t).toHaveLength(5);
    expect(t[0]).toContain("Masala Dosa");
    expect(t[0]).toContain("1.00");
    expect(t[0]).toContain("120.00");
    expect(t[1]).toContain("100.00");
  });
  it("explains an open-price item billed offline without the right", () => {
    const t = describeOfflineFlags([{ flag: "open_price_no_right", item: "Chef Special", price: 75 }]);
    expect(t).toHaveLength(1);
    expect(t[0]).toContain("Chef Special");
    expect(t[0]).toContain("75.00");
    expect(t[0]).toContain("check it");
  });
  it("explains a discount the server cut (items that cannot be discounted)", () => {
    const t = describeOfflineFlags([{ flag: "discount_cut", asked: 50, recorded: 20 }]);
    expect(t).toHaveLength(1);
    expect(t[0]).toContain("50.00");
    expect(t[0]).toContain("20.00");
    expect(t[0]).toContain("cannot be discounted");
  });
  it("handles flags written by the older function, and nothing at all", () => {
    expect(describeOfflineFlags([{ flag: "price", item: "Tea", offline_price: 5, menu_price: 10 }])).toHaveLength(1);
    expect(describeOfflineFlags(null)).toEqual([]);
    expect(describeOfflineFlags([])).toEqual([]);
    expect(describeOfflineFlags([{ flag: "something_new" }])).toEqual(["something_new"]);
  });
});
