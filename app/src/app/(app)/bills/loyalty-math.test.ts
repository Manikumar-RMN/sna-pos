import { describe, expect, it } from "vitest";
import { appliedLoyalty, discountPool, maxRedeemablePoints, pointsToAmount, receiptLoyalty, redeemBlockedReason } from "./loyalty-math";

const base = { balance: 120, pointValue: 1, minRedeem: 10, maxPercent: 100, pool: 200, manualDiscount: 0, due: 236 };

describe("discountPool", () => {
  it("leaves out blocked lines", () => {
    expect(discountPool([{ amount: 100, blocked: true }, { amount: 100.1 }, { amount: 0.2 }])).toBe(100.3);
  });
  it("is 0 when all are blocked", () => {
    expect(discountPool([{ amount: 50, blocked: true }])).toBe(0);
  });
});

describe("maxRedeemablePoints", () => {
  it("is limited by the balance", () => expect(maxRedeemablePoints(base)).toBe(120));
  it("is limited by the cap percent of the pool", () => expect(maxRedeemablePoints({ ...base, maxPercent: 25 })).toBe(50));
  it("takes the manual discount out of the room first", () => expect(maxRedeemablePoints({ ...base, manualDiscount: 150 })).toBe(50));
  it("is limited by the amount due", () => expect(maxRedeemablePoints({ ...base, due: 30 })).toBe(30));
  it("is 0 below the minimum", () => expect(maxRedeemablePoints({ ...base, balance: 9 })).toBe(0));
  it("is 0 when the room is below the minimum", () => expect(maxRedeemablePoints({ ...base, pool: 5 })).toBe(0));
  it("uses whole points for a fractional point value", () => expect(maxRedeemablePoints({ ...base, pointValue: 0.5, pool: 99 })).toBe(120));
});

describe("redeemBlockedReason", () => {
  const ok = { ...base, senior: false, hasPayments: false };
  it("null when usable", () => expect(redeemBlockedReason(ok)).toBeNull());
  it("senior", () => expect(redeemBlockedReason({ ...ok, senior: true })).toMatch(/senior/));
  it("payment", () => expect(redeemBlockedReason({ ...ok, hasPayments: true })).toMatch(/payment/));
  it("pool zero", () => expect(redeemBlockedReason({ ...ok, pool: 0 })).toBe("None of these items can be discounted."));
  it("few points", () => expect(redeemBlockedReason({ ...ok, balance: 3 })).toMatch(/at least 10/));
});

describe("helpers", () => {
  it("pointsToAmount rounds to paise", () => expect(pointsToAmount(7, 0.35)).toBe(2.45));
  it("appliedLoyalty reads calc_params", () => {
    expect(appliedLoyalty({ loyalty_points: "40", loyalty_discount: 40 })).toEqual({ points: 40, discount: 40 });
    expect(appliedLoyalty(null)).toEqual({ points: 0, discount: 0 });
  });
  it("receiptLoyalty", () => {
    expect(receiptLoyalty([{ kind: "earn", points: 12 }, { kind: "redeem", points: -40 }, { kind: "adjust", points: 10 }], 80)).toEqual({ earned: 12, redeemed: 30, balance: 80 });
    expect(receiptLoyalty([], 5)).toEqual({ earned: 0, redeemed: 0, balance: 5 });
  });
});
