import { describe, expect, it } from "vitest";
import { rightGroups, rightLabel } from "../permissions";

describe("rightGroups", () => {
  it("lists every right once", () => {
    const keys = rightGroups().flatMap((g) => g.rights.map((r) => r.key));
    expect(new Set(keys).size).toBe(keys.length);
  });
  it("names the reprint right for bills and KOTs", () => {
    expect(rightLabel("order.reprint")).toBe("Reprint bills and KOTs");
  });
  it("lists the open price right in the Billing group", () => {
    const billing = rightGroups().find((g) => g.name === "Billing");
    expect(billing?.rights.map((r) => r.key)).toContain("order.open_price");
  });
  it("falls back to the key for an unknown right", () => {
    expect(rightLabel("nothing.here")).toBe("nothing.here");
  });
  it("has a Stock group with the three stock rights", () => {
    const stock = rightGroups().find((g) => g.name === "Stock");
    expect(stock?.rights.map((r) => r.key)).toEqual(["stock.manage", "stock.view", "stock.adjust"]);
    expect(rightLabel("stock.view")).toBe("See stock, costs and stock reports");
    expect(rightLabel("stock.adjust")).toBe("Record wastage and stock counts");
    expect(rightLabel("stock.manage")).toBe("Stock, purchases and recipes");
  });
  it("has the customer view and loyalty redeem rights in the Customers group", () => {
    const c = rightGroups().find((g) => g.name === "Customers");
    expect(c?.rights.map((r) => r.key)).toEqual(["customer.view", "customer.manage", "customer.export", "loyalty.redeem"]);
    expect(rightLabel("customer.view")).toBe("See the customer list and history");
    expect(rightLabel("loyalty.redeem")).toBe("Use loyalty points on a bill");
  });
});
