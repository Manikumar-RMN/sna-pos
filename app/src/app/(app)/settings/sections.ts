import { can, has, type CurrentUser } from "@/lib/auth";
import type { SettingsLink } from "./settings-nav";

/** Setup is grouped the way Winsar and RMS group it: the property, then what you sell, then money, then people, then the system. */

/** Settings sections this person may open, in menu order. */
export function settingsSections(user: CurrentUser, taxName: string): SettingsLink[] {
  const setup = can(user, "settings.manage") || can(user, "tax.manage");
  const all: (SettingsLink & { show: boolean })[] = [
    { href: "/settings/company", label: "Company", hint: "Name, address, bill details", group: "Property", show: setup },
    { href: "/settings/bill", label: "Bill layout", hint: "Logo, paper size, what is printed", group: "Property", show: can(user, "settings.manage") },
    { href: "/settings/taxes", label: "Taxes", hint: `${taxName} rates and groups`, group: "Money", show: setup },
    { href: "/settings/charges", label: "Service charge", hint: "Kinds of bill, service and packing charge, tokens", group: "Money", show: setup },
    { href: "/settings/day", label: "Day and sessions", hint: "Shifts on/off, day end, meal sessions", group: "Property", show: can(user, "settings.manage") },
    {
      href: "/settings/reports",
      label: "Daily summary",
      hint: "Send the day's figures by email or phone alert",
      group: "Money",
      show: can(user, "settings.manage") && can(user, "report.view_sales"),
    },
    { href: "/settings/tables", label: "Tables", hint: "Dine-in tables", group: "What you sell", show: setup },
    { href: "/settings/payments", label: "Payment methods", hint: "Cash, UPI, card and more", group: "Money", show: setup },
    { href: "/settings/counters", label: "Counter tablets", hint: "Shared tablets with PIN", group: "Devices and system", show: setup },
    { href: "/settings/printers", label: "Printers", hint: "What this device prints", group: "Devices and system", show: true },
    { href: "/settings/menu", label: "Menu", hint: "Dishes, prices, add-ons", group: "What you sell", show: true },
    { href: "/settings/offers", label: "Happy hours and offers", hint: "Lower prices by day and time", group: "What you sell", show: can(user, "menu.manage") },
    { href: "/settings/brands", label: "Brands and stalls", hint: "Cloud-kitchen brands, food-court stalls, settlement", group: "What you sell", show: setup || can(user, "report.view_sales") },
    { href: "/settings/users", label: "Users", hint: "People, PINs, passwords", group: "People", show: true },
    { href: "/settings/security", label: "Security profiles", hint: "What each role can do", group: "People", show: can(user, "user.manage") },
    { href: "/settings/outlets", label: "Outlets", hint: "Prices per outlet, who works where", group: "Property", show: user.outlet_count > 1 || has(user, "multi_outlet") },
    { href: "/settings/api", label: "API keys", hint: "Connect other software", group: "Devices and system", show: can(user, "settings.manage") && has(user, "open_api") },
    { href: "/settings/plan", label: "Plan and modules", hint: "Edition, add-ons, outlets", group: "Devices and system", show: true },
  ];
  const order = ["Property", "What you sell", "Money", "People", "Devices and system"];
  return all
    .filter((s) => s.show)
    .sort((a, b) => order.indexOf(a.group) - order.indexOf(b.group))
    .map(({ href, label, hint, group }) => ({ href, label, hint, group }));
}
