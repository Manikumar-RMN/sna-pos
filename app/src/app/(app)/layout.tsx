import Link from "next/link";
import { can, requireUser } from "@/lib/auth";
import { signOut } from "@/app/login/actions";
import { NavLinks } from "./nav-links";

export default async function AppLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const user = await requireUser();

  // Show only the screens this role can use. The database enforces the real
  // rules; this just keeps the menu honest.
  const links = [
    { href: "/dashboard", label: "Home", show: true },
    { href: "/pos", label: "Bill", show: can(user, "order.create") },
    { href: "/bills", label: "Bills", show: true },
    { href: "/kitchen", label: "Kitchen", show: true },
    { href: "/shift", label: "Shift", show: can(user, "shift.open") || can(user, "shift.close") || can(user, "cash.movement") },
    { href: "/reports", label: "Reports", show: can(user, "report.view_sales") },
    { href: "/menu", label: "Menu", show: true },
    { href: "/settings/users", label: "Staff", show: true },
    { href: "/settings", label: "Settings", show: can(user, "settings.manage") || can(user, "tax.manage") },
  ]
    .filter((l) => l.show)
    .map(({ href, label }) => ({ href, label }));

  return (
    <div className="min-h-screen">
      <header className="border-b px-4 pt-3" style={{ background: "var(--color-surface)", borderColor: "var(--color-line)" }}>
        <div className="flex items-center gap-3 pb-2">
          <Link href="/dashboard" className="flex items-center gap-2.5">
            <div className="grid h-8 w-8 place-items-center rounded-lg text-[11px] font-bold text-white" style={{ background: "var(--color-brand)" }}>
              SNA
            </div>
            <div className="leading-tight">
              <div className="text-sm font-bold">SNA POS</div>
              <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                {user.trading_name}
              </div>
            </div>
          </Link>

          <div className="ml-auto flex items-center gap-3">
            <div className="text-right leading-tight">
              <div className="text-xs font-semibold">{user.full_name}</div>
              <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                {user.role_name}
              </div>
            </div>
            <form action={signOut}>
              <button type="submit" className="rounded-lg border px-3 py-2 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }}>
                Sign out
              </button>
            </form>
          </div>
        </div>
        <div className="pb-2">
          <NavLinks links={links} />
        </div>
      </header>

      <main className="px-4 py-6">{children}</main>
    </div>
  );
}
