import { can, has, type CurrentUser } from "@/lib/auth";
import type { SettingsLink } from "./settings-nav";

/** Settings sections this person may open, in menu order. */
export function settingsSections(user: CurrentUser, taxName: string): SettingsLink[] {
  const setup = can(user, "settings.manage") || can(user, "tax.manage");
  const all: (SettingsLink & { show: boolean })[] = [
    { href: "/settings/company", label: "Company", hint: "Name, address, bill details", show: setup },
    { href: "/settings/taxes", label: "Taxes", hint: `${taxName} rates and groups`, show: setup },
    { href: "/settings/charges", label: "Service charge", hint: "Service charge and rounding", show: setup },
    { href: "/settings/tables", label: "Tables", hint: "Dine-in tables", show: setup },
    { href: "/settings/payments", label: "Payment methods", hint: "Cash, UPI, card and more", show: setup },
    { href: "/settings/counters", label: "Counter tablets", hint: "Shared tablets with PIN", show: setup },
    { href: "/settings/printers", label: "Printers", hint: "What this device prints", show: true },
    { href: "/settings/menu", label: "Menu", hint: "Dishes, prices, add-ons", show: true },
    { href: "/settings/users", label: "Users", hint: "People, PINs, passwords", show: true },
    { href: "/settings/security", label: "Security profiles", hint: "What each role can do", show: can(user, "user.manage") },
    { href: "/settings/outlets", label: "Outlets", hint: "Prices per outlet, who works where", show: user.outlet_count > 1 || has(user, "multi_outlet") },
    { href: "/settings/api", label: "API keys", hint: "Connect other software", show: can(user, "settings.manage") && has(user, "open_api") },
    { href: "/settings/plan", label: "Plan and modules", hint: "Edition, add-ons, outlets", show: true },
  ];
  return all.filter((s) => s.show).map(({ href, label, hint }) => ({ href, label, hint }));
}
