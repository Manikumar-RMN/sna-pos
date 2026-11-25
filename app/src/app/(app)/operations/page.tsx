import Link from "next/link";
import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { navItems } from "../nav-items";

/** One line under each screen name, so a new member of staff knows what it is for. */
const HINTS: Record<string, string> = {
  "/pos": "Take an order and send it to the kitchen",
  "/captain": "Waiters take orders at the table",
  "/table-orders": "Orders guests placed from the QR menu",
  "/kitchen": "Tickets on the kitchen screen",
  "/bills": "Find, reprint, settle or void a bill",
  "/preorders": "Advance orders for a later date",
  "/deliveries": "Delivery orders and who is carrying them",
  "/online-orders": "Orders arriving from online partners",
  "/reservations": "Table bookings",
  "/shift": "Open and close the shift or the day, cash in and out",
  "/accounts": "Pay-later accounts and their statements",
  "/customers": "Guests, their visits and spending",
  "/loyalty": "Points and rewards",
  "/stock": "Stock, counts, wastage and expiry",
  "/purchases": "Purchase requests, orders and supplier bills",
  "/owner": "The owner's figures at a glance",
  "/reports": "All reports",
  "/timesheets": "Staff attendance",
  "/settings": "Company, taxes, printers, users and more",
  "/help": "How to use SNA POS",
};

const GROUPS: { title: string; hrefs: string[] }[] = [
  { title: "Orders and billing", hrefs: ["/pos", "/captain", "/table-orders", "/kitchen", "/bills", "/preorders", "/deliveries", "/online-orders", "/reservations"] },
  { title: "Money", hrefs: ["/shift", "/accounts"] },
  { title: "Guests", hrefs: ["/customers", "/loyalty"] },
  { title: "Stock and purchase", hrefs: ["/stock", "/purchases"] },
  { title: "Reports and team", hrefs: ["/owner", "/reports", "/timesheets"] },
  { title: "System", hrefs: ["/settings", "/help"] },
];

/** Every screen this person may open, in groups with a line each. The same screens as the side menu, in one place. */
export default async function OperationsPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const shiftsOn = !!(await supabase.from("branch_settings").select("shifts_enabled").eq("branch_id", user.branch_id).maybeSingle()).data?.shifts_enabled;
  const items = navItems(user, shiftsOn).filter((l) => l.show);

  return (
    <div className="mx-auto max-w-6xl">
      <h1 className="mb-1 text-2xl font-bold tracking-tight">Operations</h1>
      <p className="mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>Every screen you can open, in one place.</p>
      {GROUPS.map((g) => {
        const shown = g.hrefs.map((h) => items.find((i) => i.href === h)).filter((x): x is NonNullable<typeof x> => !!x);
        if (shown.length === 0) return null;
        return (
          <section key={g.title} className="mb-6" aria-label={g.title}>
            <h2 className="mb-2 text-xs font-bold uppercase tracking-wider" style={{ color: "var(--color-ink-3)" }}>{g.title}</h2>
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
              {shown.map((i) => (
                <Link key={i.href} href={i.href} className="card block p-4">
                  <div className="font-bold">{i.label}</div>
                  <div className="mt-0.5 text-sm" style={{ color: "var(--color-ink-3)" }}>{HINTS[i.href] ?? ""}</div>
                </Link>
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}
