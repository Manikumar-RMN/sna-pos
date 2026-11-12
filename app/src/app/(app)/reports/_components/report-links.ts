/** The reports under /reports, in the order they are listed on the hub. `need` is the permission that unlocks the card. */
export type ReportLink = {
  href: string;
  title: string;
  blurb: string;
  need: "sales" | "financial" | "stock" | "customers" | "loyalty" | "users";
  /** Heading the report is listed under on the hub and in the menu drop-down (the Sales summary has none). */
  group?: string;
};

export const REPORT_LINKS: ReportLink[] = [
  { href: "/reports/sales-summary", title: "Sales summary", blurb: "Sales, tax, payments, hours and items for the period.", need: "sales" },
  { group: "Operations", href: "/reports/pending-kot", title: "Pending KOT", blurb: "Kitchen tickets with food still waiting.", need: "sales" },
  { group: "Operations", href: "/reports/pending-bills", title: "Pending bills", blurb: "Open bills and bills not fully paid, with balance and age.", need: "sales" },
  { group: "Operations", href: "/reports/table-turnaround", title: "Table turnaround time", blurb: "How long each table stays occupied, by day and by table.", need: "sales" },
  { group: "Operations", href: "/reports/void-bills", title: "Void bills", blurb: "Bills that were voided, with the reason and who did it.", need: "sales" },
  { group: "Sales", href: "/reports/bills-detail", title: "Bills detail", blurb: "Every finished bill with its amounts and how it was paid.", need: "financial" },
  { group: "Sales", href: "/reports/sales-day-book", title: "Sales day book", blurb: "One line per day: bills, tax, cash and other payments.", need: "financial" },
  { group: "Sales", href: "/reports/sales-month-book", title: "Sales day book monthwise", blurb: "The same book, one line per month.", need: "financial" },
  { group: "Sales", href: "/reports/day-summary", title: "Day summary", blurb: "One page for the day: sales, discounts, tax, payments, voids and what to watch.", need: "financial" },
  { group: "Sales", href: "/reports/session-sales", title: "Session sales", blurb: "Bills, sales and top items for each meal session.", need: "sales" },
  { group: "Sales", href: "/reports/z-reading", title: "Z reading", blurb: "The reading saved at each day close, with the Z number and the accumulated grand total.", need: "financial" },
  { group: "Sales", href: "/reports/order-approval", title: "Order approval", blurb: "Table orders guests sent from the QR code: accepted, rejected, who decided and how long they waited.", need: "financial" },
  { group: "Sales", href: "/reports/group-sales", title: "Product group sales", blurb: "What each menu group sold: units, sales, discount and share.", need: "sales" },
  { group: "Sales", href: "/reports/table-sales", title: "Table wise sales", blurb: "Bills, covers and sales for each table.", need: "sales" },
  { group: "Sales", href: "/reports/kot-details", title: "KOT details", blurb: "Every kitchen ticket sent, with its items, bill, table and state.", need: "sales" },
  { group: "Sales", href: "/reports/nc-kot", title: "No-charge KOT", blurb: "Bills given free: type, reason, who allowed it and the value.", need: "financial" },
  { group: "Sales", href: "/reports/menu-list", title: "Menu list", blurb: "Every dish with its group, price, prep time and availability.", need: "sales" },
  { group: "Sales", href: "/reports/bill-changes", title: "Bill changes audit", blurb: "Bills re-opened, moved, merged, split or charged again, and who did it.", need: "financial" },
  { group: "Sales", href: "/reports/cashier-settlement", title: "Cashier settlement", blurb: "What each cashier collected in each payment mode, and refunds approved.", need: "financial" },
  { group: "Sales", href: "/reports/settlement", title: "Settlement", blurb: "Payments by mode, refunds, net collected and payment list.", need: "financial" },
  { group: "Sales", href: "/reports/covers", title: "Cover analysis", blurb: "Guests and sales per guest, by day, outlet and waiter.", need: "sales" },
  { group: "Sales", href: "/reports/tips", title: "Tips", blurb: "Tips by day, payment mode and waiter. Not part of sales.", need: "financial" },
  { group: "Sales", href: "/reports/gstr-1", title: "GSTR-1 working sheet", blurb: "India GST return figures: B2B bills, B2C by rate, credit notes, HSN summary and invoices issued.", need: "financial" },
  { group: "Sales", href: "/reports/tax", title: "Tax report", blurb: "Taxable amount and tax for each tax and rate.", need: "financial" },
  { group: "Items & staff", href: "/reports/popular-items", title: "Popular items", blurb: "The items that sell the most, by units and amount.", need: "sales" },
  { group: "Items & staff", href: "/reports/slow-items", title: "Slow and unsold items", blurb: "Menu items that sold the least, or not at all.", need: "sales" },
  { group: "Items & staff", href: "/reports/waiter-sales", title: "Waiter-wise sales", blurb: "Bills, covers and sales for each waiter or cashier.", need: "sales" },
  { group: "Items & staff", href: "/reports/discounts", title: "Discounts", blurb: "Who gave discounts, how much, and on which days.", need: "financial" },
  { group: "Customers", href: "/reports/customers", title: "Customers", blurb: "Visits, spend, new and repeat customers.", need: "customers" },
  { group: "Audit", href: "/reports/audit", title: "Voids, cancels and refunds", blurb: "Voided bills, cancelled items, refunds and credit notes.", need: "financial" },
  { group: "Audit", href: "/reports/reprints", title: "Reprints", blurb: "Bills and kitchen tickets printed again, and by whom.", need: "sales" },
  { group: "Audit", href: "/reports/user-list", title: "User list", blurb: "Everyone who can sign in, with role, department, designation, status and relieving date.", need: "users" },
  { group: "Audit", href: "/reports/leakage", title: "Leakage summary", blurb: "Voids, cancels, credit notes, discounts, free meals, reprints and moves in one place.", need: "sales" },
  { group: "Purchase and inventory", href: "/reports/stock-on-hand", title: "Stock on hand", blurb: "What is in stock now, its value, and what is low, out or negative.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/stock-movement", title: "Stock movement", blurb: "Opening, purchases, use, wastage and closing for each ingredient.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/food-cost", title: "Food cost %", blurb: "Ingredient cost against sales, by day and by dish.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/wastage", title: "Wastage", blurb: "Stock thrown away, by reason, ingredient, day and person.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/stock-ledger", title: "Stock ledger", blurb: "Every in and out of one ingredient, with a running balance and value.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/receipts", title: "Receipts list", blurb: "Every item received from suppliers, with bill, rate and value.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/supplier-purchases", title: "Supplier-wise purchases", blurb: "What you bought from each supplier, what went back, and what is still owed.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/input-tax", title: "Input tax (purchases)", blurb: "Tax paid on purchases by rate and HSN, split into CGST, SGST and IGST, with what you can claim.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/supplier-statement", title: "Supplier statement", blurb: "One supplier: bills, goods returned, payments and refunds with a running balance.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/supplier-ageing", title: "Supplier ageing", blurb: "What you owe each supplier, by how many days past the due date.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/rate-variance", title: "Rate variance", blurb: "Price paid against the rate agreed with the supplier.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/issues", title: "Issues and department use", blurb: "Stock issued to kitchen, bar and other departments, with totals.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/requests", title: "Request and requisition status", blurb: "Stock requests still to be issued and purchase requisitions and their orders.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/count-variance", title: "Stock count variance", blurb: "Where a stock count found more or less than the system, with value.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/non-moving", title: "Non-moving stock", blurb: "Stock that has not been used for a number of days.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/high-value-stock", title: "High-value stock", blurb: "Stock worth at least an amount you choose.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/abc-consumption", title: "ABC consumption", blurb: "Ingredients ranked by value used, in classes A, B and C.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/xyz-analysis", title: "XYZ analysis", blurb: "How steady the weekly use of each ingredient is.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/department-use", title: "Use by department", blurb: "Stock issued to each department (cost centre) and what it cost.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/po-variance", title: "PO rate variance", blurb: "Price paid against the price on the purchase order.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/fifo-valuation", title: "Stock value: FIFO and average", blurb: "What is on hand valued two ways: the average cost used in your books, and FIFO for comparison.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/item-stock", title: "Item stock query", blurb: "One ingredient at a glance: stock, value, last purchases, use and days of cover.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/consumption-monthly", title: "Item consumption monthwise", blurb: "How much of each ingredient went out, month by month, with value.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/mr-audit", title: "Material request audit", blurb: "Every stock request: who asked, who decided, how long it took and what was issued.", need: "stock" },
  { group: "Purchase and inventory", href: "/reports/production", title: "Production summary", blurb: "Prepared items made from ingredients: what was made, what it cost and what it used.", need: "stock" },
  { group: "Loyalty", href: "/reports/loyalty-ledger", title: "Loyalty ledger", blurb: "Points earned, used and reversed, and the points still owed.", need: "loyalty" },
];

/** What the signed-in person may see on the hub: financial reports, stock reports (stock.view) and customer reports (customer.view). */
export type ReportAccess = { financial: boolean; stock: boolean; customers: boolean; loyalty: boolean; users?: boolean };

/** Does this person see the link? Every report also needs the sales right, which the hub page itself checks. */
export function canSeeReportLink(l: Pick<ReportLink, "need">, a: ReportAccess): boolean {
  switch (l.need) {
    case "financial":
      return a.financial;
    case "stock":
      return a.stock;
    case "customers":
      return a.customers;
    case "loyalty":
      return a.loyalty;
    case "users":
      return a.users === true;
    default:
      return true;
  }
}

/** The report sections in the Reports menu, in order. POS reports is the Reports home page. */
export const REPORT_SECTIONS = [
  { key: "pos", title: "POS reports", href: "/reports" },
  { key: "inventory", title: "Purchase and inventory reports", href: "/reports/section/inventory" },
  { key: "loyalty", title: "Loyalty reports", href: "/reports/section/loyalty" },
  { key: "audit", title: "Audit reports", href: "/reports/section/audit" },
] as const;
export type SectionKey = (typeof REPORT_SECTIONS)[number]["key"];

/** Which section a report is listed in. */
export function sectionKey(l: Pick<ReportLink, "need" | "group">): SectionKey {
  if (l.need === "stock") return "inventory";
  if (l.need === "loyalty") return "loyalty";
  if (l.group === "Audit") return "audit";
  return "pos";
}

export function reportSection(l: Pick<ReportLink, "need" | "group">): string {
  const k = sectionKey(l);
  return REPORT_SECTIONS.find((x) => x.key === k)!.title;
}

/** The links this person may see, split under their headings in order (the Sales summary has no heading). Pass a section to list just that one. */
export function groupReportLinks(access: ReportAccess, section?: SectionKey): { group: string | null; items: ReportLink[] }[] {
  const out: { group: string | null; items: ReportLink[] }[] = [];
  for (const l of REPORT_LINKS) {
    if (!canSeeReportLink(l, access)) continue;
    if (section && sectionKey(l) !== section) continue;
    const g = l.group ?? null;
    const last = out[out.length - 1];
    if (last && last.group === g) last.items.push(l);
    else out.push({ group: g, items: [l] });
  }
  // A to Z: the headings, and the reports under each heading. The report with no heading (Sales summary) stays first.
  for (const o of out) o.items.sort((a, b) => a.title.localeCompare(b.title));
  return out.sort((a, b) => (a.group === null ? -1 : b.group === null ? 1 : a.group.localeCompare(b.group)));
}
