import type { CurrentUser } from "@/lib/auth";
import { can, has } from "@/lib/auth";

/**
 * The SNA Hospitality modules, one sign-in. A module shows only when the restaurant has
 * it switched on AND this person's role holds at least one of its rights. The database
 * enforces the real rules; this keeps the launcher honest. Add a module here and it
 * appears on the home screen for exactly the people allowed to use it.
 */
export type ModuleCard = { key: string; title: string; blurb: string; href: string };

export function modulesFor(user: CurrentUser): ModuleCard[] {
  const all: Array<ModuleCard & { show: boolean }> = [
    {
      key: "front_office",
      title: "Front office",
      blurb: "Rooms, reservations, check-in, folios, housekeeping, night audit",
      href: "/front-office",
      show: has(user, "front_office") && (can(user, "fo.view") || can(user, "fo.manage") || can(user, "fo.housekeeping")),
    },
    {
      key: "pos",
      title: "POS",
      blurb: "Billing, tables, kitchen, shifts and day close",
      href: "/pos",
      show: has(user, "pos") && (can(user, "order.create") || can(user, "shift.open") || can(user, "day.close")),
    },
    {
      key: "inventory",
      title: "Purchase and inventory",
      blurb: "Stock, purchases, batches",
      href: "/stock",
      show: has(user, "stock") && (can(user, "stock.view") || can(user, "stock.manage") || can(user, "stock.adjust")),
    },
    {
      key: "reports",
      title: "Reports and MIS",
      blurb: "Sales, financial and customer reports",
      href: "/reports",
      show: has(user, "reports_mis") && can(user, "report.view_sales"),
    },
    {
      key: "settings",
      title: "Setup and users",
      blurb: "Menu, staff, security profiles, company",
      href: "/settings",
      show: can(user, "settings.manage"),
    },
  ];
  return all.filter((m) => m.show).map((m) => ({ key: m.key, title: m.title, blurb: m.blurb, href: m.href }));
}
