import { describe, expect, it } from "vitest";
import { parseDiscountInput } from "../discount";

describe("parseDiscountInput", () => {
  it("treats empty as no discount", () => {
    expect(parseDiscountInput("", 100)).toEqual({ ok: true, amount: 0, percent: null });
    expect(parseDiscountInput("   ", 100)).toEqual({ ok: true, amount: 0, percent: null });
  });
  it("keeps a plain amount", () => {
    expect(parseDiscountInput("50", 200)).toEqual({ ok: true, amount: 50, percent: null });
    expect(parseDiscountInput("9.95", 99.5)).toEqual({ ok: true, amount: 9.95, percent: null });
    expect(parseDiscountInput("0", 200)).toEqual({ ok: true, amount: 0, percent: null });
  });
  it("never lets an amount go above the subtotal", () => {
    expect(parseDiscountInput("500", 120)).toEqual({ ok: true, amount: 120, percent: null });
    expect(parseDiscountInput("10", 0)).toEqual({ ok: true, amount: 0, percent: null });
  });
  it("turns a percent into an amount on the subtotal", () => {
    expect(parseDiscountInput("10%", 99.5)).toEqual({ ok: true, amount: 9.95, percent: 10 });
    expect(parseDiscountInput("10 %", 200)).toEqual({ ok: true, amount: 20, percent: 10 });
    expect(parseDiscountInput("100%", 87.65)).toEqual({ ok: true, amount: 87.65, percent: 100 });
  });
  it("rounds half up to 2 decimals", () => {
    // 12.5% of 33.33 = 4.16625 -> 4.17
    expect(parseDiscountInput("12.5%", 33.33)).toEqual({ ok: true, amount: 4.17, percent: 12.5 });
    // 15% of 0.10 = 0.015 -> 0.02
    expect(parseDiscountInput("15%", 0.1)).toEqual({ ok: true, amount: 0.02, percent: 15 });
    // 5% of 10.10 = 0.505 -> 0.51
    expect(parseDiscountInput("5%", 10.1)).toEqual({ ok: true, amount: 0.51, percent: 5 });
    // 33.333% of 100 = 33.333 -> 33.33
    expect(parseDiscountInput("33.333%", 100)).toEqual({ ok: true, amount: 33.33, percent: 33.333 });
  });
  it("gives 0 for a percent when the subtotal is 0", () => {
    expect(parseDiscountInput("10%", 0)).toEqual({ ok: true, amount: 0, percent: 10 });
  });
  it("refuses bad percents with a message", () => {
    for (const t of ["0%", "101%", "abc%", "-5%", "%", "%10", "10%%", "1e2%"]) {
      const r = parseDiscountInput(t, 100);
      expect(r.ok).toBe(false);
      if (!r.ok) expect(r.message.length).toBeGreaterThan(5);
    }
  });
  it("refuses a negative or unreadable amount", () => {
    expect(parseDiscountInput("-5", 100).ok).toBe(false);
    expect(parseDiscountInput("abc", 100).ok).toBe(false);
    expect(parseDiscountInput("1,5", 100).ok).toBe(false);
  });
  it("never goes above the subtotal for any percent from 1 to 100", () => {
    for (let p = 1; p <= 100; p += 3) {
      const r = parseDiscountInput(`${p}%`, 33.33);
      expect(r.ok).toBe(true);
      if (r.ok) expect(r.amount).toBeLessThanOrEqual(33.33);
    }
  });
});
