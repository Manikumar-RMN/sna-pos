import { describe, expect, it } from "vitest";
import {
  ageText,
  compLabel,
  methodLabel,
  monthLabel,
  parseBillsDetail,
  parseBook,
  parsePendingBills,
  parsePendingKot,
  parseSettlement,
  parseTax,
  settlementByOutlet,
  csvWithFooter,
  parseVoidBills,
  partialMonths,
  paymentsText,
  taxTotalsDiffer,
  truncationNote,
} from "../reports-pack-2";

describe("empty and broken input", () => {
  it("never throws and gives empty shapes", () => {
    for (const bad of [null, undefined, "x", 5, [], {}, { rows: null }, { rows: [null, 1, "a"] }]) {
      expect(parsePendingKot(bad).rows).toEqual([]);
      expect(parsePendingBills(bad).rows).toEqual([]);
      expect(parseBillsDetail(bad).rows).toEqual([]);
      expect(parseVoidBills(bad).rows).toEqual([]);
      expect(parseSettlement(bad).rows).toEqual([]);
      expect(parseBook(bad, "month").rows).toEqual([]);
      expect(parseTax(bad).rows).toEqual([]);
    }
    expect(parseTax(null).totals.tax).toBe(0);
    expect(parseBillsDetail(null).cap).toEqual({ truncated: false, rowLimit: 2000, totalRows: 0 });
  });
});

describe("parsePendingKot", () => {
  it("reads rows, items and totals", () => {
    const r = parsePendingKot({
      rows: [{ kitchen_ticket_id: "t1", ticket_number: "K-7", station: "Main", bill_number: "B-1", outlet_name: "A", table_number: 4, kot_time: "2026-10-25T10:00:00Z", minutes_pending: 12.9, items: [{ name: "Dosa", quantity: 2, status: "new", note: null }, { name: "Tea", quantity: "1", status: "preparing", note: "less sugar" }] }],
      totals: { kots: 1, items: 2 },
    });
    expect(r.rows[0].table).toBe("4");
    expect(r.rows[0].minutesPending).toBe(12);
    expect(r.rows[0].items[1]).toEqual({ name: "Tea", quantity: 1, status: "preparing", note: "less sugar" });
    expect(r.kots).toBe(1);
    expect(r.items).toBe(2);
  });
  it("counts from rows when totals are missing", () => {
    const r = parsePendingKot({ rows: [{ items: [{}, {}] }, {}] });
    expect(r.kots).toBe(2);
    expect(r.items).toBe(2);
  });
});

describe("parsePendingBills", () => {
  it("keeps kinds and balances; unknown kind is open", () => {
    const r = parsePendingBills({ rows: [{ kind: "unsettled", amount: "100", paid: 40, balance: 60, age_minutes: 90 }, { kind: "weird" }], totals: { bills: 2, amount: 100, paid: 40, balance: 60 } });
    expect(r.rows[0]).toMatchObject({ kind: "unsettled", amount: 100, paid: 40, balance: 60, ageMinutes: 90, waiter: null });
    expect(r.rows[1].kind).toBe("open");
    expect(r.totals).toEqual({ bills: 2, amount: 100, paid: 40, balance: 60 });
  });
});

describe("parseBillsDetail", () => {
  const json = {
    rows: [{ bill_number: "B-1", covers: 3, comp_kind: "staff_meal", grand_total: 105, service_charge: 5, payments: [{ method: "cash", kind: "cash", amount: 50 }, { method: "upi", kind: "upi", amount: 55 }, null] }],
    truncated: true,
    row_limit: 2000,
    total_rows: 2105,
    totals: { bills: 2105, grand_total: 99999.5, tax: 10 },
  };
  it("uses the database totals, not the rows", () => {
    const r = parseBillsDetail(json);
    expect(r.totals.grandTotal).toBe(99999.5);
    expect(r.totals.bills).toBe(2105);
    expect(r.rows[0].covers).toBe(3);
    expect(r.rows[0].payments).toHaveLength(2);
    expect(r.cap).toEqual({ truncated: true, rowLimit: 2000, totalRows: 2105 });
  });
  it("note only when cut", () => {
    expect(truncationNote(parseBillsDetail(json).cap, "bills")).toBe("Showing first 2000 of 2105 bills; totals cover all.");
    expect(truncationNote(parseBillsDetail({ rows: [{}], totals: {} }).cap, "bills")).toBeNull();
  });
  it("covers null stays null", () => {
    expect(parseBillsDetail({ rows: [{}] }).rows[0].covers).toBeNull();
  });
});

describe("parseVoidBills", () => {
  it("reads reason and who", () => {
    const r = parseVoidBills({ rows: [{ bill_number: "B-2", voided_by: "Asha", reason: "Wrong order", amount: 250 }, { bill_number: "B-3" }], totals: { bills: 2, amount: 250 } });
    expect(r.rows[0]).toMatchObject({ voidedBy: "Asha", reason: "Wrong order", amount: 250 });
    expect(r.rows[1].reason).toBeNull();
    expect(r.totals).toEqual({ bills: 2, amount: 250 });
  });
});

describe("parseSettlement", () => {
  it("reads modes, refunds, rows and totals", () => {
    const r = parseSettlement({
      by_mode: [{ method: "cash", kind: "cash", payments: 3, bills: 3, amount: 300, rounding: 0.5 }],
      refunds: { count: 1, amount: 20, by_mode: [{ method: "Unspecified", kind: "", count: 1, amount: 20 }] },
      rows: [{ bill_number: "B-1", method: "cash", amount: 100, reference_no: "R1" }],
      truncated: false,
      row_limit: 2000,
      total_rows: 1,
      totals: { payments: 3, amount: 300, rounding: 0.5, refunds: 20, net: 280 },
    });
    expect(r.byMode[0].rounding).toBe(0.5);
    expect(r.refunds.byMode[0].count).toBe(1);
    expect(r.rows[0].referenceNo).toBe("R1");
    expect(r.totals.net).toBe(280);
    expect(r.cap.truncated).toBe(false);
  });
});

describe("parseBook", () => {
  it("day book and month book keys, totals row", () => {
    const d = parseBook({ rows: [{ business_date: "2026-10-01", bills: 4, comp_bills: 1, grand_total: 500, cash: 200, non_cash: 300 }], totals: { bills: 4, grand_total: 500 } }, "business_date");
    expect(d.rows[0]).toMatchObject({ key: "2026-10-01", bills: 4, compBills: 1, cash: 200, nonCash: 300 });
    expect(d.totals.grandTotal).toBe(500);
    const m = parseBook({ rows: [{ month: "2026-10", days: 12 }], totals: { days: 12 } }, "month");
    expect(m.rows[0]).toMatchObject({ key: "2026-10", days: 12 });
    expect(m.totals.days).toBe(12);
  });
});

describe("partialMonths", () => {
  it("flags partial first and last months", () => {
    expect(partialMonths("2026-03-15", "2026-10-10")).toEqual({ first: "2026-03", last: "2026-10" });
    expect(partialMonths("2026-03-01", "2026-10-31")).toEqual({ first: null, last: null });
    expect(partialMonths("2026-02-01", "2026-02-28")).toEqual({ first: null, last: null });
    expect(partialMonths("2028-02-01", "2028-02-28").last).toBe("2028-02");
    expect(partialMonths("bad", "x")).toEqual({ first: null, last: null });
  });
});

describe("parseTax credit notes", () => {
  it("reads the credit-note lines and totals, and is empty without them", () => {
    const t = parseTax({ credit_rows: [{ component: "CGST", rate: 9, taxable: 100, tax: 9 }], credit_totals: { count: 1, amount: 118, tax: 18 } });
    expect(t.creditRows).toHaveLength(1);
    expect(t.credit).toEqual({ count: 1, amount: 118, tax: 18 });
    expect(parseTax(null).credit).toEqual({ count: 0, amount: 0, tax: 0 });
  });
});

describe("parseTax", () => {
  it("reads lines and both totals", () => {
    const r = parseTax({ rows: [{ component: "CGST", rate: "2.5", taxable: 1000, tax: 25 }], totals: { taxable: 1000, tax: 25, orders_tax_total: 26, tax_included: 3, exempt_sales: 40 } });
    expect(r.rows[0]).toEqual({ component: "CGST", rate: 2.5, taxable: 1000, tax: 25 });
    expect(r.totals.ordersTaxTotal).toBe(26);
    expect(taxTotalsDiffer(r.totals)).toBe(true);
    expect(taxTotalsDiffer({ tax: 25, ordersTaxTotal: 25.004 })).toBe(false);
  });
});

describe("small formatters", () => {
  it("ageText", () => {
    expect(ageText(5)).toBe("5 min");
    expect(ageText(125)).toBe("2 h 5 min");
    expect(ageText(180)).toBe("3 h");
    expect(ageText(1620)).toBe("1 d 3 h");
    expect(ageText(-4)).toBe("0 min");
  });
  it("labels", () => {
    expect(methodLabel("gift_card")).toBe("Gift card");
    expect(methodLabel(null)).toBe("Unspecified");
    expect(monthLabel("2026-10")).toBe("Oct 2026");
    expect(monthLabel("junk")).toBe("junk");
    expect(compLabel("staff_meal")).toBe("Staff meal");
    expect(compLabel(null)).toBe("");
    expect(paymentsText([{ method: "cash", kind: "cash", amount: 5 }, { method: "upi", kind: "upi", amount: 6 }], (n) => n.toFixed(2))).toBe("Cash 5.00 + UPI 6.00");
  });
});

describe("by_outlet parsing", () => {
  it("tax and settlement read by_outlet and survive missing or broken input", () => {
    const t = parseTax({ rows: [], by_outlet: [{ branch_id: "b1", outlet_name: "Main", component: "CGST", rate: 2.5, taxable: 100, tax: 2.5 }, null, 4] });
    expect(t.byOutlet).toEqual([{ branchId: "b1", outletName: "Main", component: "CGST", rate: 2.5, taxable: 100, tax: 2.5 }]);
    expect(parseTax({ by_outlet: "x" }).byOutlet).toEqual([]);
    expect(parseTax(null).byOutlet).toEqual([]);
    expect(parseTax({ by_outlet: [{}] }).byOutlet[0]).toMatchObject({ outletName: "Unknown outlet", component: "Tax", branchId: null, tax: 0 });

    const s = parseSettlement({
      by_outlet: [{ branch_id: "b1", outlet_name: "Main", method: "cash", kind: "cash", payments: 2, bills: 2, amount: 50 }, { branch_id: "b1", outlet_name: "Main", method: "upi", payments: 1, bills: 1, amount: 25 }, { branch_id: "b2", outlet_name: "Annex", payments: 1, amount: 10 }],
      refunds: { count: 1, amount: 5, by_outlet: [{ branch_id: "b1", outlet_name: "Main", count: 1, amount: 5 }] },
    });
    expect(s.byOutlet).toHaveLength(3);
    expect(s.refunds.byOutlet[0]).toEqual({ branchId: "b1", outletName: "Main", count: 1, amount: 5 });
    expect(settlementByOutlet(s)).toEqual([
      { outletName: "Main", payments: 3, amount: 75, refundCount: 1, refunds: 5, net: 70 },
      { outletName: "Annex", payments: 1, amount: 10, refundCount: 0, refunds: 0, net: 10 },
    ]);
    const empty = parseSettlement(null);
    expect(empty.byOutlet).toEqual([]);
    expect(empty.refunds.byOutlet).toEqual([]);
    expect(settlementByOutlet(empty)).toEqual([]);
    expect(parseSettlement({ by_outlet: 5, refunds: { by_outlet: "x" } }).refunds.byOutlet).toEqual([]);
  });
});

describe("csvWithFooter", () => {
  const cap = (truncated: boolean) => ({ truncated, rowLimit: 2000, totalRows: 2105 });
  it("adds a padded TOTAL row and the truncation line", () => {
    const out = csvWithFooter(4, [["a", 1, 2, 3]], ["TOTAL", 9], cap(true));
    expect(out).toEqual([["a", 1, 2, 3], ["TOTAL", 9, "", ""], ["Truncated: showing first 2000 of 2105", "", "", ""]]);
  });
  it("leaves rows alone when there is no total and nothing was cut", () => {
    expect(csvWithFooter(2, [["a", 1]], null, cap(false))).toEqual([["a", 1]]);
    expect(csvWithFooter(2, [["a", 1]], null, null)).toEqual([["a", 1]]);
  });
});
