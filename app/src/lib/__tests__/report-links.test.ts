import { describe, expect, it } from "vitest";
import { REPORT_LINKS, canSeeReportLink, groupReportLinks } from "../../app/(app)/reports/_components/report-links";

const none = { financial: false, stock: false, customers: false, loyalty: false };
const heads = (a: Parameters<typeof groupReportLinks>[0]) => groupReportLinks(a).map((g) => g.group);

describe("groupReportLinks", () => {
  it("hides Inventory and Customers without the rights", () => {
    expect(heads(none)).not.toContain("Purchase and inventory");
    expect(heads(none)).not.toContain("Customers");
    expect(heads({ ...none, financial: true })).not.toContain("Purchase and inventory");
  });
  it("shows the four inventory reports to stock.view and the two customer reports to customer.view", () => {
    const inv = groupReportLinks({ ...none, stock: true }).find((g) => g.group === "Purchase and inventory");
    expect(inv?.items.map((i) => i.href)).toEqual(["/reports/stock-on-hand", "/reports/stock-movement", "/reports/food-cost", "/reports/wastage"]);
    const cus = groupReportLinks({ ...none, customers: true, loyalty: true }).find((g) => g.group === "Customers");
    expect(cus?.items.map((i) => i.href)).toEqual(["/reports/customers"]);
    expect(groupReportLinks({ ...none, customers: true }).some((g) => g.group === "Loyalty")).toBe(false);
    expect(groupReportLinks({ ...none, loyalty: true }).some((g) => g.group === "Loyalty")).toBe(true);
  });
  it("keeps the old behaviour for sales and financial links", () => {
    const g = groupReportLinks(none);
    expect(g[0]).toMatchObject({ group: null });
    expect(g.flatMap((x) => x.items).some((l) => l.need === "financial")).toBe(false);
    expect(groupReportLinks({ ...none, financial: true }).flatMap((x) => x.items).some((l) => l.href === "/reports/tax")).toBe(true);
  });
  it("every group has one heading in a row and every link is listed once", () => {
    const all = groupReportLinks({ financial: true, stock: true, customers: true, loyalty: true });
    expect(all.flatMap((g) => g.items)).toHaveLength(REPORT_LINKS.length);
    const names = all.map((g) => g.group);
    expect(new Set(names).size).toBe(names.length);
  });
  it("canSeeReportLink", () => {
    expect(canSeeReportLink({ need: "sales" }, none)).toBe(true);
    expect(canSeeReportLink({ need: "stock" }, { ...none, financial: true })).toBe(false);
    expect(canSeeReportLink({ need: "customers" }, { ...none, customers: true })).toBe(true);
  });
});
