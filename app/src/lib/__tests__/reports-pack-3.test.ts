import { describe, expect, it } from "vitest";
import { AUDIT_ACTION_LABEL, auditDetail } from "../reports-pack";
import { coversMissingNote, paymentStatusLabel, parseCovers, parseReprints, parseTips, plural, reprintDetailText } from "../reports-pack-3";

describe("empty and broken input", () => {
  it("never throws and gives empty shapes", () => {
    for (const bad of [null, undefined, "x", 5, [], {}, { by_day: null }, { rows: [null, 1, "a"] }]) {
      const c = parseCovers(bad);
      expect(c.byDay).toEqual([]);
      expect(c.money).toBe(false);
      expect(c.totals).toEqual({ bills: 0, billsWithCovers: 0, billsWithoutCovers: 0, covers: 0, sales: null, salesPerCover: null });
      expect(parseReprints(bad).rows).toEqual([]);
      expect(parseReprints(bad).totals).toEqual({ reprints: 0, bills: 0, kots: 0 });
      expect(parseTips(bad).byDay).toEqual([]);
      expect(parseTips(bad).totals).toEqual({ tips: 0, amount: 0, bills: 0 });
    }
  });
});

describe("parseCovers", () => {
  const json = {
    money: true,
    by_day: [{ business_date: "2026-10-20", bills: 2, covers: 6, sales: 1200, sales_per_cover: 200 }],
    by_outlet: [{ branch_id: "b1", outlet_name: "Outlet A", bills: 4, covers: 8, sales: "1200.00", sales_per_cover: 150 }],
    by_waiter: [
      { user_id: "u1", staff_name: "Wendy", outlet_name: "Outlet A", bills: 3, covers: 8, sales: 1200, sales_per_cover: 150 },
      { user_id: "u2", staff_name: "Carl", outlet_name: "Outlet A", bills: 1, covers: 0, sales: 0, sales_per_cover: null },
    ],
    totals: { bills: 5, bills_with_covers: 4, bills_without_covers: 1, covers: 11, sales: 1650, sales_per_cover: 150 },
  };
  it("reads rows and totals", () => {
    const c = parseCovers(json);
    expect(c.money).toBe(true);
    expect(c.byDay[0]).toMatchObject({ label: "2026-10-20", bills: 2, covers: 6, sales: 1200, salesPerCover: 200 });
    expect(c.byOutlet[0]).toMatchObject({ label: "Outlet A", sales: 1200 });
    expect(c.byWaiter[1]).toMatchObject({ label: "Carl", covers: 0, salesPerCover: null });
    expect(c.totals).toEqual({ bills: 5, billsWithCovers: 4, billsWithoutCovers: 1, covers: 11, sales: 1650, salesPerCover: 150 });
  });
  it("keeps hidden money as null, not 0", () => {
    const c = parseCovers({ money: false, by_day: [{ business_date: "2026-10-20", bills: 1, covers: 2, sales: null, sales_per_cover: null }], totals: { bills: 1, covers: 2, sales: null, sales_per_cover: null } });
    expect(c.money).toBe(false);
    expect(c.byDay[0].sales).toBeNull();
    expect(c.totals.sales).toBeNull();
    expect(c.totals.salesPerCover).toBeNull();
  });
  it("names missing labels", () => {
    const c = parseCovers({ by_waiter: [{ bills: 1 }], by_outlet: [{ bills: 1 }] });
    expect(c.byWaiter[0].label).toBe("Unknown");
    expect(c.byOutlet[0].label).toBe("Unknown outlet");
  });
  it("coversMissingNote", () => {
    expect(coversMissingNote({ bills: 5, billsWithoutCovers: 0 })).toBe("");
    expect(coversMissingNote({ bills: 5, billsWithoutCovers: 1 })).toContain("1 of 5 dine-in bills had no guest count");
    expect(coversMissingNote({ bills: 1, billsWithoutCovers: 1 })).toContain("1 of 1 dine-in bill had");
  });
});

describe("parseReprints", () => {
  const json = {
    rows: [
      { id: 7, at: "2026-10-20T08:00:00Z", action: "kot.reprint", kind: "kot", user_name: "Carl", outlet_name: "Outlet A", bill_number: "C2", table_number: "T1", detail: { ticket_ids: ["a", "b"] } },
      { id: 6, at: "2026-10-20T07:00:00Z", action: "bill.reprint", user_name: null, bill_number: null, detail: { reprint_no: 2, reason: "Customer asked" } },
    ],
    by_user: [{ user_name: "Carl", bills: 2, kots: 1 }],
    truncated: true,
    row_limit: 2000,
    total_rows: 2105,
    totals: { reprints: 2105, bills: 2000, kots: 105 },
  };
  it("reads rows, people, cap and totals", () => {
    const r = parseReprints(json);
    expect(r.rows[0]).toMatchObject({ id: "7", kind: "kot", userName: "Carl", billNumber: "C2", table: "T1", detail: "2 tickets" });
    expect(r.rows[1]).toMatchObject({ kind: "bill", userName: "Unknown", billNumber: null, table: null, detail: "Reprint 2, Customer asked" });
    expect(r.byUser).toEqual([{ userName: "Carl", bills: 2, kots: 1 }]);
    expect(r.cap).toEqual({ truncated: true, rowLimit: 2000, totalRows: 2105 });
    expect(r.totals).toEqual({ reprints: 2105, bills: 2000, kots: 105 });
  });
  it("reprintDetailText", () => {
    expect(reprintDetailText("bill", null)).toBe("");
    expect(reprintDetailText("bill", {})).toBe("");
    expect(reprintDetailText("kot", { ticket_ids: ["x"] })).toBe("1 ticket");
    expect(reprintDetailText("bill", { ticket_ids: ["x"] })).toBe("");
    expect(reprintDetailText("bill", { reprint_no: 1, approver: "Maya" })).toBe("Reprint 1, approved by Maya");
  });
});

describe("parseTips", () => {
  it("reads groups and totals", () => {
    const t = parseTips({
      by_day: [{ business_date: "2026-10-20", tips: 2, amount: 80 }],
      by_method: [{ method: "Card", kind: "card", tips: 2, amount: "70.00" }, { method: null, tips: 1, amount: 5 }],
      by_waiter: [{ branch_id: "b", outlet_name: "Outlet A", user_id: "u", staff_name: "Wendy", tips: 2, amount: 70 }],
      by_outlet: [{ branch_id: "b", outlet_name: "Outlet A", tips: 3, amount: 100 }],
      totals: { tips: 4, amount: 140, bills: 4 },
    });
    expect(t.byDay[0]).toMatchObject({ label: "2026-10-20", tips: 2, amount: 80 });
    expect(t.byMethod.map((m) => [m.label, m.amount])).toEqual([["Card", 70], ["Unspecified", 5]]);
    expect(t.byWaiter[0]).toMatchObject({ label: "Wendy", outletName: "Outlet A", amount: 70 });
    expect(t.byOutlet[0]).toMatchObject({ label: "Outlet A", tips: 3 });
    expect(t.totals).toEqual({ tips: 4, amount: 140, bills: 4 });
  });
  it("turns bad numbers into 0", () => {
    const t = parseTips({ by_day: [{ business_date: "2026-10-20", tips: "x", amount: NaN }], totals: { tips: "?", amount: "abc" } });
    expect(t.byDay[0].tips).toBe(0);
    expect(t.byDay[0].amount).toBe(0);
    expect(t.totals).toEqual({ tips: 0, amount: 0, bills: 0 });
  });
});

describe("labels", () => {
  it("paymentStatusLabel gives plain words", () => {
    expect(paymentStatusLabel("partially_refunded")).toBe("Partly refunded");
    expect(paymentStatusLabel("unpaid")).toBe("Unpaid");
    expect(paymentStatusLabel("partial")).toBe("Part paid");
    expect(paymentStatusLabel("refunded")).toBe("Refunded");
    expect(paymentStatusLabel("paid")).toBe("");
    expect(paymentStatusLabel("")).toBe("");
    expect(paymentStatusLabel(null)).toBe("");
    expect(paymentStatusLabel("on_hold")).toBe("On hold");
  });
  it("plural", () => {
    expect(plural(1, "bill")).toBe("1 bill");
    expect(plural(0, "bill")).toBe("0 bills");
    expect(plural(2, "reprint")).toBe("2 reprints");
  });
  it("every new audit action has a plain label", () => {
    const need = ["bill.print", "bill.reprint", "kot.reprint", "order.tip", "order.open_price", "order.move_item", "menu.bulk_price_change", "menu.bulk_price_undo", "role.rights_copied", "user.access_copied", "tax.rate_scheduled", "tax.rate_schedule_cancelled"];
    for (const a of need) {
      expect(AUDIT_ACTION_LABEL[a]).toBeTruthy();
      expect(AUDIT_ACTION_LABEL[a]).not.toContain(".");
      expect(AUDIT_ACTION_LABEL[a]).not.toContain("_");
    }
  });
  it("auditDetail reads tips and open prices and does not throw on the new actions", () => {
    expect(auditDetail("order.tip", { amount: "25.5", bill_number: "B1" }, null)).toMatchObject({ bill: "B1", detail: "Tip", amount: 25.5 });
    expect(auditDetail("order.open_price", { product: "Fish", qty: 2, price: 300 }, null)).toMatchObject({ detail: "2 × Fish", amount: 300 });
    expect(auditDetail("bill.reprint", {}, null).detail).toBe("Bill reprinted");
    expect(auditDetail("role.rights_copied", null, null)).toEqual({ bill: "", detail: "", reason: "", amount: null });
  });
});
