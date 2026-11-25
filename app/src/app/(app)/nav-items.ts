import { can, has, type CurrentUser } from "@/lib/auth";

/** Every screen in the side menu, with whether this person may see it. The side menu and the Operations page both use this list. */
export function navItems(user: CurrentUser, shiftsOn: boolean): { href: string; label: string; show: boolean }[] {
  const posOn = has(user, "pos");
  const misOn = has(user, "reports_mis");
  return [
    { href: "/dashboard", label: "Home", show: true },
    { href: "/owner", label: "Owner", show: misOn && (has(user, "owner_app") && can(user, "report.view_sales")) },
    { href: "/pos", label: "KOT", show: posOn && (can(user, "order.create")) },
    { href: "/captain", label: "Captain", show: posOn && (can(user, "order.create")) },
    { href: "/preorders", label: "Pre-orders", show: posOn && (can(user, "order.create")) },
    { href: "/deliveries", label: "Deliveries", show: posOn && (can(user, "order.create")) },
    { href: "/online-orders", label: "Online orders", show: posOn && (can(user, "order.create") && has(user, "open_api")) },
    { href: "/accounts", label: "Credit accounts", show: posOn && (can(user, "payment.take") || can(user, "customer.manage")) },
    { href: "/customers", label: "Customers", show: posOn && (can(user, "customer.view") || can(user, "customer.manage")) },
    { href: "/bills", label: "Bills", show: posOn && (true) },
    { href: "/kitchen", label: "Kitchen display", show: posOn && (true) },
    { href: "/table-orders", label: "QR orders", show: posOn && (can(user, "order.create") && has(user, "qr_ordering")) },
    { href: "/shift", label: shiftsOn ? "Shift" : "Day end", show: posOn && (can(user, "shift.open") || can(user, "shift.close") || can(user, "cash.movement") || can(user, "day.close")) },
    { href: "/reports", label: "Reports", show: misOn && (can(user, "report.view_sales")) },
    { href: "/stock", label: "Inventory", show: (can(user, "stock.manage") || can(user, "stock.view") || can(user, "stock.adjust")) && has(user, "stock") },
    { href: "/purchases", label: "Purchases", show: can(user, "stock.manage") && has(user, "stock") },
    { href: "/reservations", label: "Reservations", show: posOn && (can(user, "order.create") && has(user, "reservations")) },
    { href: "/loyalty", label: "Loyalty", show: posOn && (has(user, "loyalty") && (can(user, "payment.take") || can(user, "settings.manage"))) },
    { href: "/timesheets", label: "Timesheets", show: has(user, "timesheets") },
    // Menu, users and security profiles live inside Settings.
    { href: "/settings", label: "Settings", show: true },
    { href: "/help", label: "Help", show: true },
  ];
}
