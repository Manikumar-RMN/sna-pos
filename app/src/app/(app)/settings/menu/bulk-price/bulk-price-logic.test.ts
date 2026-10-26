import { describe, expect, it } from "vitest";
import { buildScope, checkInput, descendantIds, describeChange, historyTitle, parseValue, summarize, type Preview } from "./bulk-price-logic";

describe("parseValue", () => {
  it("reads plain numbers and a decimal comma", () => {
    expect(parseValue("10")).toBe(10);
    expect(parseValue(" -5 ")).toBe(-5);
    expect(parseValue("12,5")).toBe(12.5);
    expect(parseValue("+2.5")).toBe(2.5);
  });
  it("rejects anything else", () => {
    expect(parseValue("")).toBeNull();
    expect(parseValue("ten")).toBeNull();
    expect(parseValue("1e3")).toBeNull();
    expect(parseValue("10%")).toBeNull();
  });
});

describe("buildScope", () => {
  it("is null when nothing is chosen", () => {
    expect(buildScope({ all: false, categoryIds: [], productIds: [] })).toBeNull();
  });
  it("all wins", () => {
    expect(buildScope({ all: true, categoryIds: ["a"], productIds: [] })).toEqual({ all: true });
  });
  it("removes duplicates and leaves out empty lists", () => {
    expect(buildScope({ all: false, categoryIds: ["a", "a"], productIds: [] })).toEqual({ category_ids: ["a"] });
    expect(buildScope({ all: false, categoryIds: [], productIds: ["p", "q", "p"] })).toEqual({ product_ids: ["p", "q"] });
  });
});

describe("checkInput", () => {
  const scope = { all: true };
  it("accepts a normal change", () => {
    expect(checkInput({ mode: "percent", valueText: "10", scope })).toEqual({ ok: true, value: 10 });
    expect(checkInput({ mode: "amount", valueText: "-2.5", scope })).toEqual({ ok: true, value: -2.5 });
  });
  it("refuses typos and the database limits", () => {
    expect(checkInput({ mode: "percent", valueText: "abc", scope }).ok).toBe(false);
    expect(checkInput({ mode: "percent", valueText: "0", scope }).ok).toBe(false);
    expect(checkInput({ mode: "percent", valueText: "-95", scope }).ok).toBe(false);
    expect(checkInput({ mode: "percent", valueText: "501", scope }).ok).toBe(false);
    expect(checkInput({ mode: "amount", valueText: "2000000", scope }).ok).toBe(false);
  });
  it("needs a scope", () => {
    expect(checkInput({ mode: "percent", valueText: "5", scope: null })).toEqual({ ok: false, error: "Choose which dishes to change." });
  });
});

describe("describeChange / historyTitle", () => {
  it("reads naturally", () => {
    expect(describeChange("percent", 10)).toBe("+10%");
    expect(describeChange("percent", -2.5)).toBe("-2.5%");
    expect(describeChange("amount", 2)).toBe("+2");
    expect(describeChange("amount", -0.5)).toBe("-0.50");
    expect(historyTitle({ mode: "percent", value: 10, lines: 5 })).toBe("+10% on 5 prices");
    expect(historyTitle({ mode: "amount", value: -1, lines: 1 })).toBe("-1 on 1 price");
  });
});

describe("summarize", () => {
  const line = (id: string, scope: "base" | "branch", o: number, n: number) => ({ product_id: id, name: id, category: "c", scope, branch_id: scope === "branch" ? "b" : null, branch: null, old_price: o, new_price: n });
  it("counts dishes, rises, falls and outlet prices", () => {
    const p: Preview = { lines: [line("a", "base", 100, 110), line("a", "branch", 110, 121), line("b", "base", 50, 45)], total_lines: 5, base_lines: 3, branch_lines: 2, truncated: false, include_branch: true };
    expect(summarize(p)).toEqual({ items: 2, up: 2, down: 1, outletPrices: 2, hiddenRows: 2 });
  });
});

describe("descendantIds", () => {
  it("collects sub-categories at any depth", () => {
    const cats = [
      { id: "food", parent_id: null },
      { id: "start", parent_id: "food" },
      { id: "soup", parent_id: "start" },
      { id: "drinks", parent_id: null },
    ];
    expect(descendantIds(cats, "food")).toEqual(["food", "start", "soup"]);
    expect(descendantIds(cats, "drinks")).toEqual(["drinks"]);
  });
});
