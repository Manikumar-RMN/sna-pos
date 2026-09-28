import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { signOut } from "@/app/login/actions";

export type SnaMe = { id: string; full_name: string; email: string; role: "admin" | "sales" | "implementer" | "support" };

/** SNA staff console: only people in the SNA staff list can open it. */
export default async function SnaLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");
  const { data } = await supabase.rpc("sna_me");
  const me = data as unknown as SnaMe | null;
  if (!me) redirect("/dashboard");

  const links = [
    { href: "/sna", label: "Requests and restaurants" },
    ...(me.role === "admin"
      ? [
          { href: "/sna/prices", label: "Prices" },
          { href: "/sna/staff", label: "SNA staff" },
        ]
      : []),
  ];

  return (
    <div className="min-h-screen">
      <header className="kolam px-4 py-3 text-white" style={{ background: "var(--color-brand)" }}>
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
          <div className="ml-auto flex items-center gap-2">
            <Link href="/dashboard" className="text-xs font-semibold" style={{ color: "rgba(255,255,255,0.85)" }}>
              Open POS
            </Link>
            <form action={signOut}>
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
