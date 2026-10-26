import { describe, expect, it } from "vitest";
import {
  buildCountLines,
  buildStockInLines,
  countDiff,
  countSummary,
  fmtQty,
  foodCostTone,
  invalidCountRows,
  MANUAL_REASONS,
  parseLowStock,
  parseQty,
  reasonLabel,
  recipeCost,
  STOCK_REASONS,
  stockInTotal,
  stockStatus,
  unitMismatchWarning,
} from "../stock";

describe("stockStatus", () => {
  it("follows the database rule", () => {
    expect(stockStatus(-1, 5)).toBe("negative");
    expect(stockStatus(0, 5)).toBe("out");
    expect(stockStatus(0, 0)).toBe("out");
    expect(stockStatus(5, 5)).toBe("low");
    expect(stockStatus(5.1, 5)).toBe("ok");
    expect(stockStatus(1, 0)).toBe("ok");
  });
});

describe("numbers", () => {
  it("parses quantities", () => {
    expect(parseQty("2")).toBe(2);
    expect(parseQty(" 2,5 ")).toBe(2.5);
    expect(parseQty(".5")).toBe(0.5);
    expect(parseQty("")).toBeNull();
    expect(parseQty("abc")).toBeNull();
    expect(parseQty("-1")).toBeNull();
    expect(parseQty("1e3")).toBeNull();
  });
  it("hides float noise", () => {
    expect(fmtQty(0.1 + 0.2)).toBe("0.3");
    expect(fmtQty(null)).toBe("0");
  });
});

describe("reasons", () => {
  it("has a label for every reason and keeps count_correction out of the manual list", () => {
    for (const r of STOCK_REASONS) expect(reasonLabel(r)).not.toBe(r);
    expect(MANUAL_REASONS).not.toContain("count_correction");
    expect(MANUAL_REASONS).toContain("spoilage");
    expect(reasonLabel(null)).toBe("—");
    expect(reasonLabel("new_thing")).toBe("new_thing");
  });
});

describe("buildStockInLines", () => {
  it("skips blank rows and builds lines", () => {
    const r = buildStockInLines([
      { ingredient_id: "a", qty: "10", cost: "50" },
      { ingredient_id: "", qty: "", cost: "" },
      { ingredient_id: "b", qty: "2,5", cost: "" },
    ]);
    expect(r).toEqual({
      ok: true,
      lines: [
        { ingredient_id: "a", qty: 10, unit_cost: 50 },
        { ingredient_id: "b", qty: 2.5, unit_cost: 0 },
      ],
    });
    if (r.ok) expect(stockInTotal(r.lines)).toBe(500);
  });
  it("refuses half-filled, zero, duplicate and empty input", () => {
    expect(buildStockInLines([{ ingredient_id: "", qty: "3", cost: "" }]).ok).toBe(false);
    expect(buildStockInLines([{ ingredient_id: "a", qty: "0", cost: "" }]).ok).toBe(false);
    expect(buildStockInLines([{ ingredient_id: "a", qty: "", cost: "5" }]).ok).toBe(false);
    expect(buildStockInLines([{ ingredient_id: "a", qty: "1", cost: "x" }]).ok).toBe(false);
    expect(
      buildStockInLines([
        { ingredient_id: "a", qty: "1", cost: "" },
        { ingredient_id: "a", qty: "2", cost: "" },
      ]).ok,
    ).toBe(false);
    expect(buildStockInLines([]).ok).toBe(false);
  });
});

describe("stock count", () => {
  const rows = [
    { id: "a", name: "Rice", unit: "kg", cost: 60, expected: 10, counted: "8.5" },
    { id: "b", name: "Oil", unit: "l", cost: 120, expected: 5, counted: "" },
    { id: "c", name: "Salt", unit: "kg", cost: 20, expected: 2, counted: "2" },
    { id: "d", name: "Milk", unit: "l", cost: 50, expected: -1, counted: "0" },
  ];
  it("computes difference and value, blank is not counted", () => {
    expect(countDiff(rows[0])).toEqual({ counted: 8.5, diff: -1.5, value: -90 });
    expect(countDiff(rows[1])).toBeNull();
    expect(countDiff(rows[2])).toEqual({ counted: 2, diff: 0, value: 0 });
    expect(countDiff(rows[3])).toEqual({ counted: 0, diff: 1, value: 50 });
  });
  it("sends only counted rows and summarises", () => {
    expect(buildCountLines(rows)).toEqual([
      { ingredient_id: "a", counted: 8.5 },
      { ingredient_id: "c", counted: 2 },
      { ingredient_id: "d", counted: 0 },
    ]);
    expect(countSummary(rows)).toEqual({ counted: 3, changed: 2, variance: -40 });
  });
  it("finds invalid entries", () => {
    expect(invalidCountRows([{ id: "x", counted: "abc" }, { id: "y", counted: "" }, { id: "z", counted: "3" }])).toEqual(["x"]);
  });
});

describe("recipes", () => {
  const ings = [
    { id: "a", cost: 60 },
    { id: "b", cost: 400 },
  ];
  it("costs a portion at today's cost", () => {
    expect(recipeCost([{ ingredient_id: "a", qty: "0.25" }, { ingredient_id: "b", qty: "0.05" }, { ingredient_id: "", qty: "9" }], ings, 100)).toEqual({ cost: 35, pct: 35 });
    expect(recipeCost([], ings, 0)).toEqual({ cost: 0, pct: null });
  });
  it("flags an absurd food cost", () => {
    expect(foodCostTone(null)).toBe("none");
    expect(foodCostTone(30)).toBe("ok");
    expect(foodCostTone(50)).toBe("high");
    expect(foodCostTone(240)).toBe("absurd");
    // 250 typed against a kg ingredient costing 60/kg for a 100 dish
    expect(foodCostTone(recipeCost([{ ingredient_id: "a", qty: "250" }], ings, 100).pct)).toBe("absurd");
  });
  it("warns on a grams-against-kg mix-up", () => {
    expect(unitMismatchWarning("kg", 250)).toMatch(/0\.25/);
    expect(unitMismatchWarning("kg", 0.25)).toBeNull();
    expect(unitMismatchWarning("g", 0.25)).toMatch(/not in kg/);
    expect(unitMismatchWarning("pcs", 2)).toBeNull();
    expect(unitMismatchWarning("kg", null)).toBeNull();
  });
});

describe("parseLowStock", () => {
  it("reads the list and counts", () => {
    const r = parseLowStock({
      items: [
        { ingredient_id: "a", name: "Rice", unit: "kg", on_hand: -2, reorder_level: 5 },
        { ingredient_id: "b", name: "Oil", unit: "l", on_hand: 1, reorder_level: 3 },
      ],
      counts: { out: 0, low: 1, negative: 1 },
    });
    expect(r.items.map((i) => i.status)).toEqual(["negative", "low"]);
    expect(r).toMatchObject({ out: 0, low: 1, negative: 1 });
  });
  it("survives nothing", () => {
    expect(parseLowStock(null)).toEqual({ items: [], out: 0, low: 0, negative: 0 });
    expect(parseLowStock("x").items).toEqual([]);
  });
});
