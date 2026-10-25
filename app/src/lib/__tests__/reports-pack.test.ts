import { describe, expect, it } from "vitest";
import {
  auditDetail,
  mergeCashiers,
  outletScope,
  parseDiscounts,
  parsePopular,
  parseUnsold,
  parseWaiters,
  rangeQuery,
  reportRpcError,
  resolveRange,
} from "../reports-pack";

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

describe("resolveRange clamp", () => {
  it("keeps a range of exactly 366 days and cuts a longer one to the latest 366 days", () => {
    expect(resolveRange("2026-10-20", { from: "2025-10-20", to: "2026-10-21" })).toEqual({ from: "2025-10-20", to: "2026-10-21", range: "custom" });
    expect(resolveRange("2026-10-20", { from: "2020-01-01", to: "2026-10-20" })).toEqual({
      from: "2025-10-19",
      to: "2026-10-20",
      range: "custom",
      clamped: true,
    });
  });
});

describe("reportRpcError", () => {
  it("passes the report functions' own messages through as plain words", () => {
    for (const m of [
      "You do not have the right to see financial reports.",
      "Your role does not allow this action (report.view_sales).",
      "Choose a valid date range.",
      "Choose a range of one year or less.",
    ]) {
      const e = reportRpcError({ message: m, code: "42501" });
      expect(e).toEqual({ message: m, code: "P0001" });
    }
    expect(reportRpcError({ message: "ERROR: Choose a valid date range." })?.message).toBe("Choose a valid date range.");
  });
  it("leaves other errors and no error alone", () => {
    const other = { message: "fetch failed", code: "" };
    expect(reportRpcError(other)).toBe(other);
    expect(reportRpcError(null)).toBeNull();
  });
});

describe("items", () => {
  it("reads popular items, best first as the database sent them", () => {
    const r = parsePopular([
      { product_id: "a", name: "Tea", units: 10, amount: "100.50" },
      { product_id: null, name: "Open item", units: 1, amount: 20 },
    ]);
    expect(r).toEqual([
      { key: "a", name: "Tea", qty: 10, amount: 100.5 },
      { key: "name:Open item", name: "Open item", qty: 1, amount: 20 },
    ]);
  });
  it("reads unsold and sold-least items", () => {
    const r = parseUnsold({ unsold: [{ id: "z", name: "Vada" }], sold_least: [{ product_id: "a", name: "Dosa", units: 5, amount: 250 }] });
    expect(r.dead).toEqual([{ id: "z", name: "Vada" }]);
    expect(r.slow).toEqual([{ key: "a", name: "Dosa", qty: 5, amount: 250 }]);
  });
  it("copes with empty or odd results", () => {
    expect(parsePopular(null)).toEqual([]);
    expect(parsePopular({})).toEqual([]);
    expect(parseUnsold(null)).toEqual({ dead: [], slow: [] });
    expect(parseUnsold({ unsold: "x", sold_least: [null, 3] })).toEqual({ dead: [], slow: [] });
  });
});

describe("waiters", () => {
  it("reads one row per outlet per person and works out the average bill", () => {
    const r = parseWaiters([
      { branch_id: "b1", outlet_name: "Main", user_id: "w1", staff_name: "Asha", bills: 2, covers: 5, sales: 301 },
      { branch_id: "b2", outlet_name: "Mall", user_id: "w1", staff_name: "Asha", bills: 1, covers: null, sales: 50 },
    ]);
    expect(r).toEqual([
      { branch_id: "b1", outlet_name: "Main", user_id: "w1", name: "Asha", bills: 2, covers: 5, total: 301, average: 150.5 },
      { branch_id: "b2", outlet_name: "Mall", user_id: "w1", name: "Asha", bills: 1, covers: 0, total: 50, average: 50 },
    ]);
  });
  it("is empty for nothing, and names missing people Unknown", () => {
    expect(parseWaiters([])).toEqual([]);
    expect(parseWaiters(null)).toEqual([]);
    expect(parseWaiters([{ bills: 0, sales: 0 }])[0]).toMatchObject({ name: "Unknown", outlet_name: "Unknown outlet", average: 0, user_id: null });
  });
});

describe("discounts", () => {
  const json = {
    by_cashier: [
      { branch_id: "b1", outlet_name: "Main", user_id: "c1", name: "Ravi", bills: 2, total: 70, max_pct: 50 },
      { branch_id: "b2", outlet_name: "Mall", user_id: "c1", name: "Ravi", bills: 1, total: 10, max_pct: 60 },
      { branch_id: "b2", outlet_name: "Mall", user_id: "c2", name: "Mina", bills: 1, total: 5, max_pct: 5 },
    ],
    by_day: [{ business_date: "2026-10-19", bills: 1, total: 20, max_pct: 10 }],
    by_outlet: [{ branch_id: "b1", outlet_name: "Main", bills: 2, total: 70, max_pct: 50 }],
  };
  it("reads the three views", () => {
    const r = parseDiscounts(json);
    expect(r.byDay).toEqual([{ key: "2026-10-19", name: "2026-10-19", bills: 1, total: 20, maxPercent: 10 }]);
    expect(r.byOutlet).toEqual([{ key: "b1", name: "Main", bills: 2, total: 70, maxPercent: 50 }]);
    expect(r.byCashier).toHaveLength(3);
  });
  it("merges a cashier across outlets: bills and total added, highest percent kept, biggest first", () => {
    expect(mergeCashiers(parseDiscounts(json).byCashier)).toEqual([
      { key: "c1", name: "Ravi", bills: 3, total: 80, maxPercent: 60 },
      { key: "c2", name: "Mina", bills: 1, total: 5, maxPercent: 5 },
    ]);
  });
  it("is empty for nothing", () => {
    expect(parseDiscounts(null)).toEqual({ byCashier: [], byDay: [], byOutlet: [] });
    expect(mergeCashiers([])).toEqual([]);
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

describe("rangeQuery", () => {
  it("keeps presets and custom ranges, drops the default", () => {
    expect(rangeQuery({})).toBe("");
    expect(rangeQuery({ range: "today" })).toBe("");
    expect(rangeQuery({ range: "nonsense" })).toBe("");
    expect(rangeQuery({ range: "7d" })).toBe("?range=7d");
    expect(rangeQuery({ from: "2026-10-01", to: "2026-10-05" })).toBe("?from=2026-10-01&to=2026-10-05");
  });
});

describe("outletScope", () => {
  const info = { current: "b1", all_outlets: false, outlets: [{ id: "b1", name: "Main" }, { id: "b2", name: "Mall" }] };
  it("reads one outlet when the picker is on a single outlet", () => {
    const s = outletScope(info, { id: "b1", name: "Main" });
    expect(s).toMatchObject({ all: false, branchId: "b1", label: "Outlet: Main", count: 2 });
    expect(s.names.get("b2")).toBe("Mall");
  });
  it("reads every outlet on All outlets", () => {
    const s = outletScope({ ...info, all_outlets: true }, { id: "b1", name: "Main" });
    expect(s).toMatchObject({ all: true, branchId: null, label: "All outlets" });
  });
  it("falls back to the signed-in outlet when my_outlets is missing", () => {
    expect(outletScope(null, { id: "b9", name: "Solo" })).toMatchObject({ all: false, branchId: "b9", label: "Outlet: Solo", count: 1 });
  });
});
