import { describe, expect, it } from "vitest";
import {
  aggregateItems,
  aggregateWaiters,
  auditDetail,
  discountPercent,
  discountsByDay,
  discountsByUser,
  resolveRange,
  splitPopularSlow,
  type OrderRow,
} from "../reports-pack";

const order = (o: Partial<OrderRow>): OrderRow => ({
  business_date: "2026-10-20",
  cashier_id: "c1",
  waiter_id: null,
  covers: null,
  grand_total: 100,
  subtotal: 100,
  discount_total: 0,
  ...o,
});

describe("resolveRange", () => {
  it("defaults to the business day", () => {
    expect(resolveRange("2026-10-20", {})).toEqual({ from: "2026-10-20", to: "2026-10-20", range: "today" });
    expect(resolveRange("2026-10-20", { range: "nonsense" }).range).toBe("today");
  });
  it("handles presets", () => {
    expect(resolveRange("2026-10-20", { range: "yesterday" })).toEqual({ from: "2026-10-19", to: "2026-10-19", range: "yesterday" });
    expect(resolveRange("2026-10-20", { range: "7d" }).from).toBe("2026-10-14");
    expect(resolveRange("2026-10-20", { range: "month" }).from).toBe("2026-10-01");
    expect(resolveRange("2026-10-20", { range: "lastmonth" })).toEqual({ from: "2026-09-01", to: "2026-09-30", range: "lastmonth" });
  });
  it("swaps a backwards custom range", () => {
    expect(resolveRange("2026-10-20", { from: "2026-10-10", to: "2026-10-05" })).toEqual({ from: "2026-10-05", to: "2026-10-10", range: "custom" });
  });
});

describe("items", () => {
  const lines = [
    { product_id: "a", product_name: "Dosa", quantity: 2, line_subtotal: "100.00" },
    { product_id: "a", product_name: "Dosa", quantity: 3, line_subtotal: 150 },
    { product_id: "b", product_name: "Tea", quantity: 10, line_subtotal: 100 },
    { product_id: null, product_name: "Open item", quantity: 1, line_subtotal: 20 },
  ];
  it("adds up units and amount per item, most units first", () => {
    const r = aggregateItems(lines);
    expect(r.map((x) => [x.name, x.qty, x.amount])).toEqual([
      ["Tea", 10, 100],
      ["Dosa", 5, 250],
      ["Open item", 1, 20],
    ]);
  });
  it("splits slow and unsold items among active menu items only", () => {
    const sold = aggregateItems(lines);
    const active = [
      { id: "a", name: "Dosa" },
      { id: "b", name: "Tea" },
      { id: "z", name: "Vada" },
      { id: "y", name: "Idli" },
    ];
    const r = splitPopularSlow(sold, active, { slow: 1 });
    expect(r.dead.map((d) => d.name)).toEqual(["Idli", "Vada"]);
    expect(r.slow.map((s) => s.name)).toEqual(["Dosa"]);
    expect(r.popular[0].name).toBe("Tea");
  });
  it("copes with an empty range", () => {
    expect(splitPopularSlow([], [])).toEqual({ popular: [], slow: [], dead: [] });
  });
});

describe("waiters", () => {
  it("falls back to the cashier and averages the bill", () => {
    const r = aggregateWaiters([
      order({ waiter_id: "w1", grand_total: 200, covers: 2 }),
      order({ waiter_id: "w1", grand_total: 101, covers: 3 }),
      order({ waiter_id: null, cashier_id: "c1", grand_total: 50 }),
    ]);
    expect(r).toEqual([
      { user_id: "w1", bills: 2, covers: 5, total: 301, average: 150.5 },
      { user_id: "c1", bills: 1, covers: 0, total: 50, average: 50 },
    ]);
  });
  it("is empty for no bills", () => {
    expect(aggregateWaiters([])).toEqual([]);
  });
});

describe("discounts", () => {
  const rows = [
    order({ cashier_id: "c1", subtotal: 200, discount_total: 20, business_date: "2026-10-19" }),
    order({ cashier_id: "c1", subtotal: 100, discount_total: 50, business_date: "2026-10-20" }),
    order({ cashier_id: "c2", subtotal: 100, discount_total: 5, business_date: "2026-10-20" }),
    order({ cashier_id: "c2", subtotal: 100, discount_total: 0, business_date: "2026-10-20" }),
  ];
  it("computes the percent of the menu value", () => {
    expect(discountPercent(200, 20)).toBe(10);
    expect(discountPercent(0, 20)).toBe(0);
    expect(discountPercent(100, 0)).toBe(0);
    expect(discountPercent(10, 99)).toBe(100);
  });
  it("groups by cashier and ignores bills with no discount", () => {
    expect(discountsByUser(rows)).toEqual([
      { key: "c1", bills: 2, total: 70, maxPercent: 50 },
      { key: "c2", bills: 1, total: 5, maxPercent: 5 },
    ]);
  });
  it("groups by day, oldest first", () => {
    expect(discountsByDay(rows)).toEqual([
      { key: "2026-10-19", bills: 1, total: 20, maxPercent: 10 },
      { key: "2026-10-20", bills: 2, total: 55, maxPercent: 50 },
    ]);
  });
});

describe("auditDetail", () => {
  it("reads a void", () => {
    expect(auditDetail("order.void", { status: "voided", reason: "Wrong table" }, { grand_total: 540 })).toEqual({
      bill: "",
      detail: "Whole bill voided",
      reason: "Wrong table",
      amount: 540,
    });
  });
  it("reads a cancelled item", () => {
    const d = auditDetail("order.cancel_item", { bill_number: "B-12", item: "Dosa", qty: 2, reason: "Guest left" }, { qty: 2 });
    expect(d.bill).toBe("B-12");
    expect(d.detail).toBe("2 × Dosa");
    expect(d.reason).toBe("Guest left");
  });
  it("reads kitchen ticket cancels, credit notes, complimentary bills and approvals", () => {
    expect(auditDetail("kot.cancel", { ticket: "K-7", items: 3, reason: "Mistake" }, null)).toEqual({
      bill: "",
      detail: "Ticket K-7, 3 item(s)",
      reason: "Mistake",
      amount: null,
    });
    expect(auditDetail("credit_note.issue", { number: "CN-1", bill_number: "B-9", amount: 120.5, reason: "Cold food" }, null)).toEqual({
      bill: "B-9",
      detail: "Credit note CN-1",
      reason: "Cold food",
      amount: 120.5,
    });
    expect(auditDetail("order.complimentary", { bill_number: "B-3", kind: "staff_meal", reason: "Shift meal", value: 300 }, null)).toEqual({
      bill: "B-3",
      detail: "Staff meal",
      reason: "Shift meal",
      amount: 300,
    });
    expect(auditDetail("order.complimentary", { kind: "complimentary", value: 80 }, null).detail).toBe("Complimentary");
    expect(auditDetail("approval.granted", { approver: "Asha", permission: "order.void" }, null)).toEqual({
      bill: "",
      detail: "Asha approved order.void",
      reason: "",
      amount: null,
    });
  });
  it("survives missing or odd payloads", () => {
    expect(auditDetail("order.refund", null, null)).toEqual({ bill: "", detail: "Refund", reason: "", amount: null });
    expect(auditDetail("order.adjust", "text", [1])).toMatchObject({ amount: null });
  });
});
