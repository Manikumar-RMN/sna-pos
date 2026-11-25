import type { Metadata } from "next";
import Link from "next/link";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { createConsoleClient as createClient } from "@/lib/supabase/server";
import { CONSOLE_COOKIE } from "../console-cookie";
import { signOutOfConsole } from "../login/actions";
import { ConsoleNav } from "./console-nav";

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
    { href: "/sna/money", label: "Money" },
    ...(me.role === "admin"
      ? [
          { href: "/sna/prices", label: "Prices" },
          { href: "/sna/staff", label: "Our team" },
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
              For SNA staff
            </div>
          </div>
          <ConsoleNav links={links} />
          <details className="relative ml-auto">
            <summary
              className="flex min-h-10 cursor-pointer list-none items-center gap-2 rounded-xl border px-3 text-xs font-bold"
              style={{ borderColor: "rgba(255,255,255,0.3)" }}
            >
              <span aria-hidden className="flex h-6 w-6 items-center justify-center rounded-full text-[11px]" style={{ background: "rgba(255,255,255,0.2)" }}>
                {me.full_name.trim().charAt(0).toUpperCase()}
              </span>
              Account
            </summary>
            <div className="absolute right-0 z-20 mt-2 w-56 rounded-xl border p-2 text-sm shadow-lg" style={{ background: "var(--color-surface)", borderColor: "var(--color-line)", color: "var(--color-ink)" }}>
              <div className="px-3 py-2">
                <div className="font-semibold">{me.full_name}</div>
                <div className="text-xs capitalize" style={{ color: "var(--color-ink-3)" }}>
                  {me.role} · {me.email}
                </div>
              </div>
              <Link href="/sna/password" className="block rounded-lg px-3 py-2 font-semibold">
                Change password
              </Link>
              <form action={signOutOfConsole}>
                <button className="w-full rounded-lg px-3 py-2 text-left font-semibold" style={{ color: "var(--color-bad)" }}>
                  Sign out
                </button>
              </form>
            </div>
          </details>
        </div>
      </header>
      <main className="mx-auto max-w-6xl px-4 py-5">{children}</main>
    </div>
  );
}
