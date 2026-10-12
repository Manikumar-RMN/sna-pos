import type { Metadata } from "next";
import Link from "next/link";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createConsoleClient as createClient } from "@/lib/supabase/server";
import { CONSOLE_COOKIE } from "../console-cookie";
import { signOutOfConsole } from "../login/actions";

export const metadata: Metadata = { title: "SNA console", robots: { index: false, follow: false } };

export type SnaMe = { id: string; full_name: string; email: string; role: "admin" | "sales" | "implementer" | "support" };

/**
 * SNA console: SNA's own back office. It is not part of the restaurant app.
 * It has its own sign-in page (/sna/login), nothing in the restaurant app
 * links to it, and being signed in to a restaurant does not open it.
 *
 * The database is the real guard: every sna_* function checks that the caller
 * is in the SNA staff list. The checks here only decide which page to show.
 */
export default async function SnaLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/sna/login");
  // Set only by the console's own sign-in, and tied to the person who signed in there.
  if ((await cookies()).get(CONSOLE_COOKIE)?.value !== user.id) redirect("/sna/login");
  const { data } = await supabase.rpc("sna_me");
  const me = data as unknown as SnaMe | null;
  if (!me) redirect("/sna/login");

  const links = [
    { href: "/sna", label: "Clients" },
    { href: "/sna/new", label: "New client" },
    ...(me.role === "admin"
      ? [
          { href: "/sna/prices", label: "Prices" },
          { href: "/sna/staff", label: "SNA staff" },
        ]
      : []),
    { href: "/sna/help", label: "Help" },
  ];

  return (
    <div className="min-h-screen">
      {/* Dark bar, not the restaurant app's green one, so the two are never mistaken for each other. */}
      <header className="px-4 py-3 text-white" style={{ background: "var(--color-ink)" }}>
        <div className="mx-auto flex max-w-6xl flex-wrap items-center gap-3">
          <div className="leading-tight">
            <div className="font-display text-lg font-bold">SNA console</div>
            <div className="text-xs" style={{ color: "rgba(255,255,255,0.8)" }}>
              {me.full_name} · {me.role}
            </div>
          </div>
          <nav className="flex flex-wrap gap-1 text-sm">
            {links.map((l) => (
              <Link key={l.href} href={l.href} className="rounded-xl px-3 py-2 font-semibold" style={{ color: "rgba(255,255,255,0.9)" }}>
                {l.label}
              </Link>
            ))}
          </nav>
          <div className="ml-auto flex items-center gap-3">
            <Link href="/sna/password" className="text-xs font-semibold" style={{ color: "rgba(255,255,255,0.85)" }}>
              Change password
            </Link>
            <form action={signOutOfConsole}>
              <button className="min-h-10 rounded-xl border px-3 text-xs font-bold" style={{ borderColor: "rgba(255,255,255,0.3)" }}>
                Sign out
              </button>
            </form>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-5">{children}</main>
    </div>
  );
}
