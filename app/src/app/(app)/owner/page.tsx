import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { AlertsSwitch, InstallButton, LiveRefresh } from "./owner-parts";

type Outlet = { outlet: string; bills: number; total: number; average: number; discounts: number; voids: number; void_value: number };

/** The owner's phone screen: today's sales per outlet and the alerts feed. Installs as an app. */
export default async function OwnerPage() {
  const user = await requireUser();
  if (!has(user, "owner_app")) {
    return <p className="card p-5 text-sm">The owner mobile app is an add-on. Ask for it in Settings → Plan and modules.</p>;
  }
  if (!can(user, "report.view_sales")) return <p className="card p-5 text-sm">This screen is for owners and managers.</p>;
  const today = new Date().toLocaleDateString("en-CA", { timeZone: user.timezone });
  const supabase = await createClient();
  const [{ data: cmp }, { data: alerts }, { count: openBills }] = await Promise.all([
    supabase.rpc("outlet_comparison", { p_from: today, p_to: today }),
    supabase.from("owner_alerts").select("id, title, body, created_at").order("created_at", { ascending: false }).limit(40),
    supabase.from("orders").select("id", { count: "exact", head: true }).in("payment_status", ["unpaid", "partial"]).neq("status", "voided"),
  ]);
  const outlets = (cmp as unknown as Outlet[] | null) ?? [];
  const m = (n: number) => money(n, user.currency_code);
  const total = outlets.reduce((s, o) => s + Number(o.total), 0);
  const bills = outlets.reduce((s, o) => s + Number(o.bills), 0);
  const voids = outlets.reduce((s, o) => s + Number(o.voids), 0);

  return (
    <div className="mx-auto max-w-lg space-y-4">
      <LiveRefresh seconds={60} />
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold tracking-tight">Today at {user.trading_name}</h1>
        <InstallButton />
      </div>

      <section className="grid grid-cols-2 gap-3">
        <div className="card p-4">
          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>Sales today</div>
          <div className="font-display text-2xl font-bold tabular-nums">{m(total)}</div>
        </div>
        <div className="card p-4">
          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>Bills</div>
          <div className="font-display text-2xl font-bold tabular-nums">{bills}</div>
        </div>
        <div className="card p-4">
          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>Open bills (this outlet)</div>
          <div className="font-display text-2xl font-bold tabular-nums">{openBills ?? 0}</div>
        </div>
        <div className="card p-4">
          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>Voided bills</div>
          <div className="font-display text-2xl font-bold tabular-nums" style={{ color: voids ? "var(--color-bad)" : undefined }}>{voids}</div>
        </div>
      </section>

      {outlets.length > 1 && (
        <section className="card p-4">
          <h2 className="mb-2 text-sm font-bold">By outlet</h2>
          <ul className="space-y-1 text-sm">
            {outlets.map((o) => (
              <li key={o.outlet} className="flex justify-between">
                <span>{o.outlet} · {o.bills} bills</span>
                <b className="tabular-nums">{m(Number(o.total))}</b>
              </li>
            ))}
          </ul>
        </section>
      )}

      <AlertsSwitch vapidKey={process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY ?? ""} />

      <section className="card p-4">
        <h2 className="mb-2 text-sm font-bold">Alerts</h2>
        {(alerts ?? []).length === 0 && <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No alerts yet. Voids, refunds, discounts, cash differences and day close show here.</p>}
        <ul className="space-y-2">
          {(alerts ?? []).map((a) => (
            <li key={a.id} className="border-b pb-2 text-sm" style={{ borderColor: "var(--color-line)" }}>
              <div className="flex justify-between gap-2">
                <b>{a.title}</b>
                <span className="shrink-0 text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {new Date(a.created_at).toLocaleString("en-IN", { timeZone: user.timezone, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })}
                </span>
              </div>
              <div style={{ color: "var(--color-ink-2)" }}>{a.body}</div>
            </li>
          ))}
        </ul>
      </section>

      <div className="flex gap-2">
        <Link href="/reports" className="btn flex-1 border" style={{ borderColor: "var(--color-line)" }}>Reports</Link>
        <Link href="/bills" className="btn flex-1 border" style={{ borderColor: "var(--color-line)" }}>Bills</Link>
      </div>
    </div>
  );
}
