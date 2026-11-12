import { can, has, type CurrentUser } from "@/lib/auth";
import type { SettingsLink } from "./settings-nav";

/** Setup is grouped by module: General (shared by every module), POS, Inventory, POS reports. A module the client did not buy shows no group. */

/** Settings sections this person may open, in menu order. */
export function settingsSections(user: CurrentUser, taxName: string): SettingsLink[] {
  const setup = can(user, "settings.manage") || can(user, "tax.manage");
  const pos = has(user, "pos");
  const all: (SettingsLink & { show: boolean })[] = [
    { href: "/settings/company", label: "Company", hint: "Name, tax number, address", group: "General", show: setup },
    { href: "/settings/business-type", label: "Type of business", hint: "Restaurant, café, QSR, bar and more", group: "POS", show: pos && can(user, "settings.manage") },
    { href: "/settings/bill-details", label: "Bill details", hint: "FSSAI, SAC code, receipt wording, Kitchen screen", group: "POS", show: pos && can(user, "settings.manage") },
    { href: "/settings/bill", label: "Bill layout", hint: "Logo, paper size, what is printed", group: "POS", show: pos && (can(user, "settings.manage")) },
    { href: "/settings/taxes", label: "Taxes", hint: `${taxName} rates and groups`, group: "General", show: setup },
    { href: "/settings/charges", label: "Service charge", hint: "Kinds of bill, service and packing charge, tokens", group: "POS", show: pos && (setup) },
    { href: "/settings/day", label: "Day and sessions", hint: "Shifts on/off, day end, meal sessions", group: "POS", show: pos && (can(user, "settings.manage")) },
    {
      href: "/settings/reports",
      label: "Daily summary",
      hint: "Send the day's figures by email or phone alert",
      group: "Reports",
      show: has(user, "reports_mis") && can(user, "settings.manage") && can(user, "report.view_sales"),
    },
    { href: "/settings/tables", label: "Tables", hint: "Dine-in tables", group: "POS", show: pos && (setup) },
    { href: "/settings/payments", label: "Payment methods", hint: "Cash, UPI, card and more", group: "General", show: setup },
    { href: "/settings/printers", label: "Printers", hint: "What this device prints", group: "General", show: true },
    { href: "/settings/menu", label: "Menu", hint: "Dishes, prices, add-ons", group: "POS", show: pos && (true) },
    { href: "/settings/offers", label: "Happy hours and offers", hint: "Lower prices by day and time", group: "POS", show: pos && (can(user, "menu.manage")) },
    { href: "/settings/nc-charge", label: "No-charge accounts", hint: "Who bears the cost of a free bill", group: "POS", show: pos && can(user, "settings.manage") },
    { href: "/settings/discounts", label: "Discounts", hint: "Saved discounts and the maximum allowed", group: "POS", show: pos && can(user, "settings.manage") },
    { href: "/settings/brands", label: "Brands and stalls", hint: "Cloud-kitchen brands, food-court stalls, settlement", group: "POS", show: pos && (setup || can(user, "report.view_sales")) },
    { href: "/settings/users", label: "Users", hint: "People, PINs, passwords", group: "General", show: true },
    { href: "/settings/security", label: "Security profiles", hint: "What each role can do", group: "General", show: can(user, "user.manage") },
    { href: "/settings/outlets", label: "Outlets", hint: "Prices per outlet, who works where", group: "POS", show: user.outlet_count > 1 || has(user, "multi_outlet") },
    { href: "/settings/api", label: "API keys", hint: "Connect other software", group: "General", show: can(user, "settings.manage") && has(user, "open_api") },
    { href: "/settings/plan", label: "Plan and modules", hint: "Modules you have and what you can add", group: "General", show: true },
    { href: "/settings/item-groups", label: "Item groups and departments", hint: "How stock items are grouped", group: "Purchase and inventory", show: has(user, "stock") && can(user, "stock.manage") },
    { href: "/settings/purchase-rules", label: "Purchase rules", hint: "Who approves purchases, limits", group: "Purchase and inventory", show: has(user, "stock") && can(user, "stock.manage") },
    { href: "/settings/purchase-rates", label: "Agreed supplier rates", hint: "Rates fixed with each supplier", group: "Purchase and inventory", show: has(user, "stock") && can(user, "stock.manage") },
  ];
  const order = ["General", "POS", "Purchase and inventory", "Reports"];
  return all
    .filter((s) => s.show)
    .sort((a, b) => order.indexOf(a.group) - order.indexOf(b.group) || a.label.localeCompare(b.label))
    .map(({ href, label, hint, group }) => ({ href, label, hint, group }));
}
