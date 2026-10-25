/** The reports under /reports, in the order they are listed on the hub. `need` is the permission that unlocks the card. */
export type ReportLink = {
  href: string;
  title: string;
  blurb: string;
  need: "sales" | "financial";
};

export const REPORT_LINKS: ReportLink[] = [
  { href: "/reports", title: "Sales summary", blurb: "Sales, tax, payments, hours and items for the period.", need: "sales" },
  { href: "/reports/popular-items", title: "Popular items", blurb: "The items that sell the most, by units and amount.", need: "sales" },
  { href: "/reports/slow-items", title: "Slow and unsold items", blurb: "Menu items that sold the least, or not at all.", need: "sales" },
  { href: "/reports/waiter-sales", title: "Waiter-wise sales", blurb: "Bills, covers and sales for each waiter or cashier.", need: "sales" },
  { href: "/reports/discounts", title: "Discounts", blurb: "Who gave discounts, how much, and on which days.", need: "financial" },
  { href: "/reports/audit", title: "Voids, cancels and refunds", blurb: "Voided bills, cancelled items, refunds and credit notes.", need: "financial" },
];
