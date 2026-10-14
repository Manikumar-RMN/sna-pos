import { describe, expect, it } from "vitest";
import { calcBill, roundCash, type CalcInput } from "../calc-bill";
import golden from "./calc-bill.golden.json";

const cents = (x: number) => Math.round(x * 100);

describe("calcBill matches the live database function", () => {
  for (const c of golden.cases) {
    it(`case ${c.case}`, () => {
      const r = calcBill(c.input as CalcInput);
      expect(cents(r.grand_total)).toBe(cents(c.expected.grand_total));
      expect(cents(r.tax_total)).toBe(cents(c.expected.tax_total));
      expect(cents(r.service_charge)).toBe(cents(c.expected.service_charge));
      expect(cents(r.discount)).toBe(cents(c.expected.discount));
      expect(cents(r.senior_discount)).toBe(cents(c.expected.senior_discount));
      expect(cents(r.rounding)).toBe(cents(c.expected.rounding));
    });
  }
});

describe("calcBill invariants on random bills", () => {
  let seed = 987654321;
  const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
  const R = (a: number, b: number) => a + rnd() * (b - a);
  const ri = (a: number, b: number) => Math.floor(R(a, b + 1));

  it("line totals add up to the bill, taxes add up, nothing is negative (5000 bills)", () => {
    for (let t = 0; t < 5000; t++) {
      const lines = Array.from({ length: ri(1, 8) }, (_, i) => ({
        key: i + 1,
        price: Math.round(R(0, 2000) * 100) / 100 + (rnd() < 0.3 ? 0.005 : 0),
        qty: rnd() < 0.3 ? Math.round(R(0.1, 5) * 1000) / 1000 : ri(1, 12),
        inclusive: rnd() < 0.4,
        comps: Array.from({ length: ri(0, 3) }, (_, k) => ({ name: "T" + k, rate: [0, 2.5, 5, 9, 12, 18, 28][ri(0, 6)], compound: rnd() < 0.2 })),
      }));
      const sub = lines.reduce((s, l) => s + l.price * l.qty, 0);
      const input: CalcInput = {
        lines,
        discount: rnd() < 0.5 ? Math.round(R(0, sub * 1.2) * 100) / 100 : 0,
        sc_percent: rnd() < 0.4 ? 10 : 0,
        sc_taxable: rnd() < 0.5,
        rounding: ["none", "nearest_1", "nearest_0_05", "nearest_0_10"][ri(0, 3)],
      };
      const r = calcBill(input);
      expect(r.lines.reduce((s, l) => s + cents(l.total), 0)).toBe(cents(r.before_round));
      expect(r.taxes.reduce((s, x) => s + cents(x.amount), 0)).toBe(cents(r.tax_total));
      expect(r.lines.every((l) => l.total >= 0 && l.net >= 0)).toBe(true);
      expect(r.grand_total).toBeGreaterThanOrEqual(0);
      expect(cents(r.discount)).toBeLessThanOrEqual(cents(r.subtotal));
    }
  });

  it("refuses an invalid discount / senior combination", () => {
    const line = { key: 1, price: 100, qty: 1, comps: [] };
    expect(() => calcBill({ lines: [line], discount: -1 })).toThrow();
    expect(() => calcBill({ lines: [line], discount: 10, senior: { share: 0.5 } })).toThrow();
    expect(() => calcBill({ lines: [line], senior: { share: 1.5 } })).toThrow();
  });

  it("empty bill is zero", () => {
    expect(calcBill({ lines: [] }).grand_total).toBe(0);
  });

  it("cash rounding goes half away from zero", () => {
    expect(roundCash(1002, "nearest_0_05")).toBe(1000);
    expect(roundCash(1003, "nearest_0_05")).toBe(1005);
    expect(roundCash(150, "nearest_1")).toBe(200);
    expect(roundCash(149, "nearest_1")).toBe(100);
    expect(roundCash(12345, "none")).toBe(12345);
  });
});
