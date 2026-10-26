import { describe, expect, it } from "vitest";
import { parseWarnings, qtyShort, stripText, warnedProducts, warningText, type StockWarning } from "./stock-warning";

const w = (extra: Partial<StockWarning>): StockWarning => ({ ingredient_id: "i", name: "Rice", unit: "kg", need: 0.5, on_hand: 0.2, after: -0.3, level: "out", ...extra });

describe("stock warning wording", () => {
  it("short stock: the example sentence from the plan", () => {
    expect(warningText(w({}))).toBe("Rice: only 0.2 kg left, this order needs 0.5 kg.");
  });
  it("none left, and negative books", () => {
    expect(warningText(w({ on_hand: 0, after: -0.5 }))).toBe("Rice: none left, this order needs 0.5 kg.");
    expect(warningText(w({ on_hand: -1.25, after: -1.75 }))).toContain("-1.25 kg on the books");
  });
  it("low", () => {
    expect(warningText(w({ level: "low", on_hand: 5, after: 1 }))).toBe("Rice: running low, 1 kg will be left after this order.");
  });
  it("numbers have no float noise", () => {
    expect(qtyShort(0.30000000000000004)).toBe("0.3");
    expect(qtyShort(2)).toBe("2");
    expect(qtyShort(-0.0001)).toBe("0");
    expect(qtyShort(NaN)).toBe("0");
  });
});

describe("parseWarnings / stripText", () => {
  it("ignores anything unexpected", () => {
    expect(parseWarnings(null)).toEqual([]);
    expect(parseWarnings({})).toEqual([]);
    expect(parseWarnings({ warnings: "x" })).toEqual([]);
    expect(parseWarnings({ warnings: [null, 3, { name: "A", level: "weird" }] })).toEqual([]);
  });
  it("sorts out before low, worst first, and keeps product ids", () => {
    const list = parseWarnings({
      warnings: [
        { ingredient_id: "a", name: "Oil", unit: "l", need: 1, on_hand: 3, after: 2, level: "low" },
        { ingredient_id: "b", name: "Rice", unit: "kg", need: 2, on_hand: 1, after: -1, level: "out", product_ids: ["p1", 7] },
        { ingredient_id: "c", name: "Dal", unit: "kg", need: 5, on_hand: 1, after: -4, level: "out" },
      ],
    });
    expect(list.map((x) => x.name)).toEqual(["Dal", "Rice", "Oil"]);
    expect([...warnedProducts(list)]).toEqual(["p1"]);
  });
  it("the strip shows three and counts the rest; no warnings, no strip", () => {
    expect(stripText([])).toBeNull();
    const many = Array.from({ length: 5 }, (_, i) => w({ name: `I${i}` }));
    const s = stripText(many)!;
    expect(s.lines).toHaveLength(3);
    expect(s.more).toBe(2);
    expect(s.footer).toBe("You can still bill.");
  });
});
