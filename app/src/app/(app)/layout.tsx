import Link from "next/link";
import { requireUser } from "@/lib/auth";
import { signOut } from "@/app/login/actions";

export default async function AppLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const user = await requireUser();

  return (
    <div className="min-h-screen">
      <header
        className="flex flex-wrap items-center gap-3 border-b px-4 py-3"
        style={{ background: "var(--color-surface)", borderColor: "var(--color-line)" }}
      >
        <div className="flex items-center gap-2.5">
          <div
            className="grid h-8 w-8 place-items-center rounded-lg text-[11px] font-bold text-white"
            style={{ background: "var(--color-brand)" }}
          >
            SNA
          </div>
          <div className="leading-tight">
            <div className="text-sm font-bold">SNA POS</div>
            <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
              {user.trading_name}
            </div>
          </div>
        </div>

        <nav className="flex items-center gap-1 text-sm">
          <Link href="/dashboard" className="rounded-lg px-3 py-2 font-medium hover:bg-[var(--color-ground)]">
            Dashboard
          </Link>
          <Link href="/menu" className="rounded-lg px-3 py-2 font-medium hover:bg-[var(--color-ground)]">
            Menu
          </Link>
          <Link href="/settings/users" className="rounded-lg px-3 py-2 font-medium hover:bg-[var(--color-ground)]">
            Users
          </Link>
        </nav>

        <div className="ml-auto flex items-center gap-3">
          <div className="text-right leading-tight">
            <div className="text-xs font-semibold">{user.full_name}</div>
            <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
              {user.role_name}
            </div>
          </div>
          <form action={signOut}>
            <button
              type="submit"
              className="rounded-lg border px-3 py-2 text-xs font-semibold"
              style={{ borderColor: "var(--color-line)" }}
            >
              Sign out
            </button>
          </form>
        </div>
      </header>

      <main className="px-4 py-6">{children}</main>
    </div>
  );
}
