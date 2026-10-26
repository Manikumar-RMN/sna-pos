import { describe, expect, it } from "vitest";
import { loyaltyLines, pointsText } from "../receipt-loyalty";

describe("receipt points block", () => {
  it("prints nothing without a guest or without any points", () => {
    expect(loyaltyLines(null)).toEqual([]);
    expect(loyaltyLines(undefined)).toEqual([]);
    expect(loyaltyLines({ earned: 0, redeemed: 0, balance: 0 })).toEqual([]);
  });
  it("earned, used and balance", () => {
    expect(loyaltyLines({ earned: 12, redeemed: 0, balance: 130 })).toEqual([
      { label: "Points earned", value: "12" },
      { label: "Points balance", value: "130" },
    ]);
    expect(loyaltyLines({ earned: 0, redeemed: 50, balance: 80 }).map((x) => x.label)).toEqual(["Points used", "Points balance"]);
  });
  it("shows the balance of a guest who earned nothing today", () => {
    expect(loyaltyLines({ earned: 0, redeemed: 0, balance: 40 })).toEqual([{ label: "Points balance", value: "40" }]);
  });
  it("whole points have no decimals", () => {
    expect(pointsText(12)).toBe("12");
    expect(pointsText(12.5)).toBe("12.50");
  });
});
