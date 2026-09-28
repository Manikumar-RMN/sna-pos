/**
 * The rights a security profile (role) can have, grouped the way an owner thinks
 * about them. The database enforces every one of these; this file only names
 * and groups them for the screens.
 */
export type RightGroup = { name: string; rights: { key: string; label: string; hint?: string }[] };

export function rightGroups(taxName = "tax"): RightGroup[] {
  return [
    {
      name: "Billing",
      rights: [
        { key: "order.create", label: "Take orders and send to kitchen" },
        { key: "order.discount", label: "Give discounts" },
        { key: "order.void", label: "Void bills and cancel items" },
        { key: "order.reprint", label: "Reprint bills" },
      ],
    },
    {
      name: "Payments",
      rights: [
        { key: "payment.take", label: "Take payment" },
        { key: "payment.change_mode", label: "Change payment mode on a paid bill", hint: "While the shift is open" },
        { key: "cash.movement", label: "Cash in / out of the drawer" },
        { key: "order.refund", label: "Refund with a credit note" },
      ],
    },
    {
      name: "Shift and reports",
      rights: [
        { key: "shift.open", label: "Open a shift" },
        { key: "shift.close", label: "Close a shift and count cash" },
        { key: "day.close", label: "Close the day (end-of-day report)" },
        { key: "day.reopen", label: "Reopen the last closed day" },
        { key: "report.view_sales", label: "See sales reports" },
        { key: "report.view_financial", label: `See ${taxName} and cash figures` },
      ],
    },
    {
      name: "Menu",
      rights: [
        { key: "menu.manage", label: "Add and edit dishes" },
        { key: "menu.price_change", label: "Change prices" },
      ],
    },
    {
      name: "Customers",
      rights: [
        { key: "customer.manage", label: "Add and edit customers" },
        { key: "customer.export", label: "Export the customer list" },
      ],
    },
    {
      name: "Settings and users",
      rights: [
        { key: "settings.manage", label: "Change settings" },
        { key: "tax.manage", label: `Change ${taxName} rates` },
        { key: "user.manage", label: "Add and manage users" },
      ],
    },
    {
      name: "Assistant",
      rights: [
        { key: "agent.use", label: "Use the assistant" },
        { key: "agent.configure", label: "Set up the assistant" },
        { key: "agent.approve_action", label: "Approve assistant actions" },
      ],
    },
  ];
}

/** Plain label for one right. */
export function rightLabel(key: string, taxName = "tax"): string {
  for (const g of rightGroups(taxName)) for (const r of g.rights) if (r.key === key) return r.label;
  return key;
}

/** The order roles are shown in; custom roles come after these. */
export const ROLE_ORDER = ["Owner", "Manager", "Cashier", "Steward", "Waiter", "Chef"];

export function sortRoles<T extends { name: string }>(roles: T[]): T[] {
  const rank = (n: string) => {
    const i = ROLE_ORDER.indexOf(n);
    return i === -1 ? ROLE_ORDER.length : i;
  };
  return [...roles].sort((a, b) => rank(a.name) - rank(b.name) || a.name.localeCompare(b.name));
}
