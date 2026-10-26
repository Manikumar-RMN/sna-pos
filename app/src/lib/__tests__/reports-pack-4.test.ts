import { describe, expect, it } from "vitest";
import {
  attentionOnly,
  captureNote,
  coverageNote,
  dishesWithoutRecipe,
  ledgerKind,
  movementKindLabel,
  parseCustomers,
  parseFoodCost,
  parseLoyaltyLedger,
  parseStockMovement,
  parseStockOnHand,
  parseWastage,
  pctText,
  qtyText,
  ratePct,
  signedPoints,
  stockStatus,
  unitLabel,
} from "../reports-pack-4";
import { AUDIT_ACTION_LABEL } from "../reports-pack";

describe("empty and broken input", () => {
  it("never throws and gives empty shapes", () => {
    for (const bad of [null, undefined, "x", 5, [], {}, { rows: null }, { rows: [null, 1, "a"], by_day: "x" }]) {
      expect(parseStockOnHand(bad).rows).toEqual([]);
      expect(parseStockOnHand(bad).totals).toEqual({ value: 0, items: 0, low: 0, out: 0, negative: 0 });
      expect(parseStockMovement(bad).rows).toEqual([]);
      expect(parseStockMovement(bad).summary).toEqual([]);
      expect(parseStockMovement(bad).totals).toEqual({ lines: 0, movements: 0, purchasedValue: 0, usedValue: 0, wastedValue: 0, adjustedValue: 0, countedValue: 0 });
      expect(parseFoodCost(bad).byDish).toEqual([]);
      expect(parseFoodCost(bad).totals.costPct).toBeNull();
      expect(parseWastage(bad).rows).toEqual([]);
      expect(parseWastage(bad).totals).toEqual({ lines: 0, value: 0 });
      expect(parseCustomers(bad).byCustomer).toEqual([]);
      expect(parseCustomers(bad).money).toBe(false);
      expect(parseLoyaltyLedger(bad).rows).toEqual([]);
      expect(parseLoyaltyLedger(bad).liability).toEqual({ pointsOutstanding: 0, rupeeValue: null, customersWithPoints: 0 });
    }
  });
});

describe("formatters", () => {
  it("units and quantities", () => {
    expect(unitLabel("l")).toBe("L");
    expect(unitLabel("bunch")).toBe("bunch");
    expect(qtyText(2.5, "kg")).toBe("2.5 kg");
    expect(qtyText(2.00049, "kg")).toBe("2 kg");
    expect(qtyText(-1.2, "l")).toBe("-1.2 L");
    expect(qtyText(null, "kg")).toBe("—");
    expect(qtyText(3)).toBe("3");
  });
  it("percent and points", () => {
    expect(pctText(32.54)).toBe("32.5%");
    expect(pctText(null)).toBe("—");
    expect(signedPoints(120)).toBe("+120");
    expect(signedPoints(-50)).toBe("-50");
    expect(signedPoints(0)).toBe("0");
    expect(ratePct(0.42)).toBeCloseTo(0.42);
    expect(ratePct(42)).toBe(42);
    expect(ratePct(0)).toBe(0);
    expect(ratePct(null)).toBeNull();
  });
});

describe("parseStockOnHand", () => {
  const json = {
    rows: [
      { branch_id: "b1", outlet_name: "Main", ingredient_id: "i1", name: "Rice", category: "Grain", unit: "kg", on_hand: "12.5", cost: 60, value: 750, reorder_level: 5, status: "ok" },
      { branch_id: "b1", outlet_name: "Main", ingredient_id: "i2", name: "Milk", category: "Dairy", unit: "l", on_hand: 1, cost: 50, value: 50, reorder_level: 3, status: "low" },
      { branch_id: "b1", outlet_name: "Main", ingredient_id: "i3", name: "Paneer", category: "Dairy", unit: "kg", on_hand: -2, cost: 300, value: 0, reorder_level: null, status: "negative" },
      { branch_id: "b1", outlet_name: "Main", ingredient_id: "i4", name: "Oil", unit: "l", on_hand: 0, cost: null, value: null, status: "weird" },
    ],
    totals: { value: 800, items: 4, low: 1, out: 1, negative: 1 },
  };
  it("reads rows and totals", () => {
    const s = parseStockOnHand(json);
    expect(s.rows[0]).toMatchObject({ name: "Rice", onHand: 12.5, cost: 60, value: 750, reorderLevel: 5, status: "ok" });
    expect(s.rows[2]).toMatchObject({ onHand: -2, value: 0, status: "negative", reorderLevel: null });
    expect(s.rows[3]).toMatchObject({ cost: null, value: null, status: "ok", category: "" });
    expect(s.totals).toEqual({ value: 800, items: 4, low: 1, out: 1, negative: 1 });
  });
  it("status and attention filter", () => {
    expect(stockStatus("out")).toBe("out");
    expect(stockStatus(undefined)).toBe("ok");
    expect(attentionOnly(parseStockOnHand(json).rows).map((r) => r.name)).toEqual(["Milk", "Paneer"]);
  });
  it("items falls back to the row count", () => {
    expect(parseStockOnHand({ rows: [{ name: "A" }], totals: {} }).totals.items).toBe(1);
  });
});

describe("parseStockMovement", () => {
  // The shape migration 144 returns: rows = one per ingredient, details = the newest lines.
  const json = {
    all_outlets: false,
    rows: [{ branch_id: "b1", outlet_name: "Main", ingredient_id: "i1", name: "Rice", unit: "kg", opening: 10, purchased: 20, transfer_in: 0, transfer_out: 1, used: 8, wasted: 0.5, adjusted: 0, counted: -0.5, closing: 20 }],
    details: [
      { id: "m1", business_date: "2026-10-20", at: "2026-10-20T10:00:00Z", outlet_name: "Main", name: "Rice", unit: "kg", kind: "purchase", qty: 20, unit_cost: 60, value: 1200, reason: null, note: "Invoice 4", bill_number: null, user_name: "Ravi" },
      { id: "m2", business_date: "2026-10-20", at: "2026-10-20T12:00:00Z", name: "Rice", unit: "kg", kind: "sale", qty: -1, unit_cost: 60, value: -60, bill_number: "INV-9", user_name: "Sam" },
    ],
    truncated: false, row_limit: 2000, total_rows: 2,
    totals: { rows: 1, movements: 2, purchased_value: 1200, used_value: 60, wasted_value: 30, adjusted_value: 0, counted_value: -30 },
  };
  it("reads the summary, the detail and totals", () => {
    const m = parseStockMovement(json);
    expect(m.summary[0]).toMatchObject({ name: "Rice", opening: 10, purchased: 20, transferOut: 1, used: 8, wasted: 0.5, closing: 20 });
    expect(m.rows[0]).toMatchObject({ kind: "purchase", qty: 20, unitCost: 60, value: 1200, note: "Invoice 4", userName: "Ravi" });
    expect(m.rows[1]).toMatchObject({ billNumber: "INV-9", qty: -1, outletName: "" });
    expect(m.totals).toEqual({ lines: 1, movements: 2, purchasedValue: 1200, usedValue: 60, wastedValue: 30, adjustedValue: 0, countedValue: -30 });
    expect(m.cap).toEqual({ truncated: false, rowLimit: 2000 });
  });
  it("flags a capped list", () => {
    expect(parseStockMovement({ truncated: true, row_limit: 2000, details: [] }).cap.truncated).toBe(true);
    const many = { details: Array.from({ length: 2000 }, () => ({ kind: "sale" })) };
    expect(parseStockMovement(many).cap.truncated).toBe(true);
  });
  it("kind labels", () => {
    expect(movementKindLabel("sale")).toBe("Used in sale");
    expect(movementKindLabel("transfer_in")).toBe("Transfer in");
    expect(movementKindLabel("some_new_kind")).toBe("Some new kind");
    expect(movementKindLabel("")).toBe("Other");
  });
});

describe("parseFoodCost", () => {
  const json = {
    by_day: [{ business_date: "2026-10-20", net_sales_covered: 1000, cost: 320, cost_pct: 32 }],
    by_dish: [
      { product_id: "p1", name: "Dosa", qty_sold: 10, net_sales: 1000, cost: 320, cost_pct: 32, margin: 680, has_recipe: true },
      { product_id: "p2", name: "Tea", qty_sold: 5, net_sales: 500, cost: null, cost_pct: null, margin: null, has_recipe: false },
    ],
    totals: { net_sales_all: 1500, net_sales_covered: 1000, coverage_pct: 66.7, cost: 320, cost_pct: 32 },
    wastage_cost: 45.5,
  };
  it("reads days, dishes, totals and wastage", () => {
    const f = parseFoodCost(json);
    expect(f.byDay[0]).toEqual({ businessDate: "2026-10-20", netSalesCovered: 1000, cost: 320, costPct: 32 });
    expect(f.byDish[0]).toMatchObject({ name: "Dosa", cost: 320, margin: 680, hasRecipe: true });
    expect(f.byDish[1]).toMatchObject({ name: "Tea", cost: null, costPct: null, margin: null, hasRecipe: false });
    expect(f.totals).toEqual({ netSalesAll: 1500, netSalesCovered: 1000, coveragePct: 66.7, cost: 320, costPct: 32 });
    expect(f.wastageCost).toBe(45.5);
  });
  it("a dish with no cost is without a recipe even if flagged", () => {
    const f = parseFoodCost({ by_dish: [{ name: "X", cost: null, has_recipe: true }] });
    expect(f.byDish[0].hasRecipe).toBe(false);
  });
  it("lists dishes without a recipe and words the coverage", () => {
    const f = parseFoodCost(json);
    expect(dishesWithoutRecipe(f.byDish).map((d) => d.name)).toEqual(["Tea"]);
    expect(coverageNote(f.totals, 1)).toContain("66.7% of sales");
    expect(coverageNote(f.totals, 1)).toContain("1 dish sold without a recipe");
    expect(coverageNote(f.totals, 3)).toContain("3 dishes");
    expect(coverageNote({ ...f.totals, coveragePct: 100 }, 0)).toContain("Every dish");
    expect(coverageNote({ ...f.totals, coveragePct: null }, 0)).toBe("");
  });
});

describe("parseWastage", () => {
  const json = {
    by_reason: [{ reason: "Spoiled", lines: 2, value: 90 }],
    by_ingredient: [{ ingredient_id: "i1", name: "Milk", unit: "l", lines: 2, qty: 3, value: 90 }],
    by_day: [{ business_date: "2026-10-20", lines: 2, value: 90 }],
    by_user: [{ user_id: "u1", staff_name: "Ravi", lines: 2, value: 90 }],
    rows: [{ business_date: "2026-10-20", outlet_name: "Main", ingredient: "Milk", unit: "l", qty: -2, unit_cost: 30, value: 60, reason: "Spoiled", note: "", user: "Ravi" }],
    totals: { lines: 2, value: 90 },
  };
  it("reads groups, rows and totals", () => {
    const w = parseWastage(json);
    expect(w.byReason[0]).toEqual({ label: "Spoiled", lines: 2, qty: null, value: 90 });
    expect(w.byIngredient[0]).toMatchObject({ label: "Milk", unit: "l", qty: 3, value: 90 });
    expect(w.byUser[0].label).toBe("Ravi");
    expect(w.byDay[0].label).toBe("2026-10-20");
    expect(w.rows[0]).toMatchObject({ qty: 2, value: 60, userName: "Ravi" });
    expect(w.totals).toEqual({ lines: 2, value: 90 });
  });
  it("accepts the qty_lines spelling and falls back to the row count", () => {
    expect(parseWastage({ totals: { qty_lines: 7, value: 1 } }).totals.lines).toBe(7);
    expect(parseWastage({ rows: [{}, {}], totals: {} }).totals.lines).toBe(2);
  });
});

describe("parseCustomers", () => {
  const json = {
    money: true,
    by_customer: [
      { customer_id: "c1", name: "Asha", phone: "9876543210", visits: 3, spend: 1500, avg_bill: 500, first_visit_on: "2026-10-01", last_visit_on: "2026-10-20", is_new: false },
      { customer_id: "c2", name: "Bala", phone: "", visits: 1, spend: 200, avg_bill: 200, first_visit_on: "2026-10-20", last_visit_on: "2026-10-20", is_new: true },
    ],
    by_day: [{ business_date: "2026-10-20", bills_with_customer: 2, new_customers: 1, repeat_customers: 1, spend: 700 }],
    totals: { customers: 2, new: 1, repeat: 1, repeat_rate: 50, spend: 1700, bills_with_customer: 4, bills_total: 10, capture_rate: 40 },
  };
  it("reads rows and totals", () => {
    const c = parseCustomers(json);
    expect(c.money).toBe(true);
    expect(c.byCustomer[0]).toMatchObject({ name: "Asha", visits: 3, spend: 1500, avgBill: 500, isNew: false });
    expect(c.byCustomer[1]).toMatchObject({ isNew: true, phone: "" });
    expect(c.byDay[0]).toMatchObject({ billsWithCustomer: 2, newCustomers: 1, repeatCustomers: 1, spend: 700 });
    expect(c.totals).toEqual({ customers: 2, new: 1, repeat: 1, repeatRate: 50, spend: 1700, billsWithCustomer: 4, billsTotal: 10, captureRate: 40 });
  });
  it("keeps hidden money as null, not 0", () => {
    const c = parseCustomers({ money: false, by_customer: [{ name: "A", visits: 1, spend: null, avg_bill: null }], totals: { spend: null } });
    expect(c.money).toBe(false);
    expect(c.byCustomer[0].spend).toBeNull();
    expect(c.byCustomer[0].avgBill).toBeNull();
    expect(c.totals.spend).toBeNull();
  });
  it("capture note", () => {
    expect(captureNote({ billsWithCustomer: 4, billsTotal: 10 })).toBe("4 of 10 bills had a customer attached; only those are in this report.");
    expect(captureNote({ billsWithCustomer: 0, billsTotal: 1 })).toContain("0 of 1 bill had");
    expect(captureNote({ billsWithCustomer: 0, billsTotal: 0 })).toBe("");
  });
});

describe("parseLoyaltyLedger", () => {
  const json = {
    by_day: [{ business_date: "2026-10-20", earned: 100, redeemed: 40, reversed: 10, adjusted: 5 }],
    rows: [
      { at: "2026-10-20T10:00:00Z", customer: "Asha", kind: "earn", points: 100, bill_number: "INV-1", outlet: "Main", user: "Ravi" },
      { at: "2026-10-20T11:00:00Z", customer: "Asha", kind: "redeem", points: -40, bill_number: "INV-2", outlet: "Main", user: "Ravi" },
      { at: "2026-10-20T12:00:00Z", customer: "Bala", kind: "adjust", points: 5, bill_number: null, outlet: null, user: "Owner" },
      { customer: "Cy", kind: "expiry", points: -3 },
    ],
    totals: { earned: 100, redeemed: 40, reversed: 10, adjusted: 5, net: 55 },
    liability: { points_outstanding: 500, rupee_value: 50, customers_with_points: 12 },
  };
  it("reads rows, totals and liability", () => {
    const l = parseLoyaltyLedger(json);
    expect(l.rows[0]).toMatchObject({ kind: "earned", kindText: "Earned", points: 100, billNumber: "INV-1", outlet: "Main" });
    expect(l.rows[1]).toMatchObject({ kind: "redeemed", points: -40 });
    expect(l.rows[2]).toMatchObject({ kind: "adjusted", billNumber: null, outlet: "Manual" });
    expect(l.rows[3]).toMatchObject({ kind: "other", kindText: "expiry", userName: "" });
    expect(l.byDay[0]).toEqual({ businessDate: "2026-10-20", earned: 100, redeemed: 40, reversed: 10, adjusted: 5 });
    expect(l.totals).toEqual({ earned: 100, redeemed: 40, reversed: 10, adjusted: 5, net: 55 });
    expect(l.liability).toEqual({ pointsOutstanding: 500, rupeeValue: 50, customersWithPoints: 12 });
  });
  it("kinds", () => {
    expect(ledgerKind("earned")).toBe("earned");
    expect(ledgerKind("reversal")).toBe("reversed");
    expect(ledgerKind(null)).toBe("other");
  });
});

describe("audit labels added in batch 3", () => {
  it("every new action has a plain label", () => {
    for (const a of ["stock.in", "stock.wastage", "stock.adjust", "stock.count", "menu.discount_flag", "menu.prep_time", "loyalty.redeem_discount", "loyalty.redeem_removed", "customer.updated", "customer.forgotten", "customer.export"]) {
      expect(AUDIT_ACTION_LABEL[a]).toBeTruthy();
      expect(AUDIT_ACTION_LABEL[a]).not.toContain(".");
      expect(AUDIT_ACTION_LABEL[a]).not.toContain("_");
    }
  });
});
