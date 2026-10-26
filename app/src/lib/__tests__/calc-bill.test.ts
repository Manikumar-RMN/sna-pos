import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
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

/**
 * Every calc-bill.<name>.golden.json in this folder is run too: drop in the numbers the database oracle produced
 * (same shape as calc-bill.golden.json; `expected` may also carry loyalty_discount, discountable_subtotal and
 * per-line {key, discount, tax, total}) and they are checked without touching this file.
 */
type Extra = {
  case: string | number;
  oracle?: string;
  input: CalcInput;
  expected: Record<string, number | { key: number; discount: number; tax: number; total: number }[]>;
};
const dir = __dirname;
const extraFiles = readdirSync(dir).filter((f) => /^calc-bill\..+\.golden\.json$/.test(f)).sort();
for (const f of extraFiles) {
  const file = JSON.parse(readFileSync(join(dir, f), "utf8")) as { cases: Extra[] };
  describe(`calcBill matches ${f}`, () => {
    for (const c of file.cases) {
      it(`${c.case}${c.oracle ? ` [${c.oracle}]` : ""}`, () => {
        const r = calcBill(c.input);
        for (const k of ["grand_total", "tax_total", "service_charge", "discount", "loyalty_discount", "discountable_subtotal", "senior_discount", "rounding"] as const) {
          const want = c.expected[k];
          if (typeof want === "number") expect(cents(r[k]), k).toBe(cents(want));
        }
        const wl = c.expected.lines;
        if (Array.isArray(wl)) {
          for (const w of wl) {
            const got = r.lines.find((l) => l.key === w.key)!;
            expect(cents(got.discount), `line ${w.key} discount`).toBe(cents(w.discount));
            expect(cents(got.tax), `line ${w.key} tax`).toBe(cents(w.tax));
            expect(cents(got.total), `line ${w.key} total`).toBe(cents(w.total));
          }
        }
      });
    }
  });
}

describe("calcBill discount block (restricted lines)", () => {
  const gst = [{ name: "CGST", rate: 9 }, { name: "SGST", rate: 9 }];
  const line = (key: number, price: number, qty = 1, extra: Partial<CalcInput["lines"][number]> = {}) => ({ key, price, qty, inclusive: false, comps: gst, ...extra });

  it("plan example: a restricted line takes no discount and keeps its full tax", () => {
    const r = calcBill({ lines: [line(1, 100, 1, { no_disc: true }), line(2, 100)], discount: 20 });
    expect(r.lines[0].discount).toBe(0);
    expect(r.lines[0].tax).toBe(18);
    expect(r.lines[1].discount).toBe(20);
    expect(r.lines[1].tax).toBe(14.4);
    // 118.00 + 94.40. (The plan text says 232.40; that is an addition slip, the lines are right.)
    expect(r.grand_total).toBe(212.4);
    expect(r.discountable_subtotal).toBe(100);
  });

  it("a flag of false or missing changes nothing", () => {
    const a = calcBill({ lines: [line(1, 100), line(2, 100)], discount: 20 });
    const b = calcBill({ lines: [line(1, 100, 1, { no_disc: false }), line(2, 100)], discount: 20 });
    expect(b).toEqual(a);
    expect(a.discountable_subtotal).toBe(a.subtotal);
    expect(a.loyalty_discount).toBe(0);
  });

  it("random bills: restricted lines never get a discount, the parts add up, the cap is the pool", () => {
    let seed = 24681357;
    const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;
    const R = (a: number, b: number) => a + rnd() * (b - a);
    const ri = (a: number, b: number) => Math.floor(R(a, b + 1));
    for (let t = 0; t < 4000; t++) {
      const lines = Array.from({ length: ri(1, 8) }, (_, i) => ({
        key: i + 1,
        price: Math.round(R(0, 900) * 100) / 100,
        qty: ri(1, 6),
        inclusive: rnd() < 0.4,
        no_disc: rnd() < 0.4,
        comps: Array.from({ length: ri(0, 2) }, (_, k) => ({ name: "T" + k, rate: [0, 5, 12, 18][ri(0, 3)], compound: rnd() < 0.2 })),
      }));
      const pool = lines.filter((l) => !l.no_disc).reduce((s, l) => s + Math.round(l.price * l.qty * 100), 0) / 100;
      const manual = rnd() < 0.6 ? Math.round(R(0, pool * 1.3 + 1) * 100) / 100 : 0;
      const loyalty = rnd() < 0.3 ? Math.round(R(0, pool * 1.3 + 1) * 100) / 100 : 0;
      const r = calcBill({ lines, discount: manual, loyalty_discount: loyalty, rounding: "none" });
      expect(cents(r.discountable_subtotal)).toBe(Math.round(pool * 100));
      const taken = r.lines.reduce((s, l) => s + cents(l.discount), 0);
      expect(taken).toBe(cents(r.discount) + cents(r.loyalty_discount));
      expect(taken).toBeLessThanOrEqual(Math.round(pool * 100));
      expect(cents(r.discount)).toBe(Math.min(cents(manual), Math.round(pool * 100)));
      expect(cents(r.loyalty_discount)).toBe(Math.min(cents(loyalty), Math.round(pool * 100) - cents(r.discount)));
      for (const l of r.lines) {
        const src = lines.find((x) => x.key === l.key)!;
        if (src.no_disc) expect(l.discount).toBe(0);
        expect(cents(l.discount)).toBeLessThanOrEqual(cents(l.subtotal));
        expect(l.discount).toBeGreaterThanOrEqual(0);
      }
      expect(r.lines.reduce((s, l) => s + cents(l.total), 0)).toBe(cents(r.before_round));
    }
  });

  it("all lines restricted: nothing is taken off", () => {
    const r = calcBill({ lines: [line(1, 100, 1, { no_disc: true })], discount: 30, loyalty_discount: 10 });
    expect(r.discount).toBe(0);
    expect(r.loyalty_discount).toBe(0);
    expect(r.discountable_subtotal).toBe(0);
    expect(r.grand_total).toBe(118);
  });

  it("loyalty points: after the manual discount, capped at the pool, refused on a senior bill", () => {
    const r = calcBill({ lines: [line(1, 100, 1, { no_disc: true }), line(2, 100)], discount: 50, loyalty_discount: 80 });
    expect(r.discount).toBe(50);
    expect(r.loyalty_discount).toBe(50);
    expect(() => calcBill({ lines: [line(1, 100)], loyalty_discount: 10, senior: { share: 0.5 } })).toThrow();
    expect(() => calcBill({ lines: [line(1, 100)], loyalty_discount: -1 })).toThrow();
  });
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
