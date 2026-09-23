import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

export default async function DashboardPage() {
  const user = await requireUser();
  const supabase = await createClient();

  // Every one of these reads is scoped by Row Level Security to this user's
  // own restaurant. No restaurant_id filter is written here, and none is
  // needed — the database applies it.
  const [branches, staff, taxGroups, paymentMethods] = await Promise.all([
    supabase.from("branches").select("id", { count: "exact", head: true }),
    supabase.from("users").select("id", { count: "exact", head: true }),
    supabase.from("tax_groups").select("id", { count: "exact", head: true }),
    supabase.from("payment_methods").select("id", { count: "exact", head: true }),
  ]);

  const stats = [
    { label: "Branches", value: branches.count ?? 0 },
    { label: "Staff", value: staff.count ?? 0 },
    { label: "Tax groups", value: taxGroups.count ?? 0 },
    { label: "Payment methods", value: paymentMethods.count ?? 0 },
  ];

  return (
    <div className="mx-auto max-w-4xl">
      <h1 className="text-xl font-bold tracking-tight">
        {user.trading_name}
      </h1>
      <p className="mt-1 mb-6 text-sm" style={{ color: "var(--color-ink-3)" }}>
        {user.country_code} · {user.currency_code} · {user.timezone}
      </p>

      <div className="mb-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        {stats.map((s) => (
          <div key={s.label} className="card p-4">
            <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              {s.label}
            </div>
            <div className="mt-1 text-2xl font-bold tabular-nums">{s.value}</div>
          </div>
        ))}
      </div>

      <div className="card p-5">
        <h2 className="text-base font-bold">What works so far</h2>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          Stage 2 of the build: accounts, restaurant setup, roles and
          permissions. Billing comes next.
        </p>
        <ul className="mt-4 space-y-2 text-sm">
          <li>✅ Sign in and sign out</li>
          <li>✅ Restaurant setup with India&rsquo;s GST structure</li>
          <li>✅ Five staff roles with separated permissions</li>
          <li>⬜ Menu management — Stage 3</li>
          <li>⬜ Billing, payment and receipt — Stage 4</li>
          <li>⬜ Offline billing — Stage 5</li>
        </ul>
      </div>

      <p className="mt-6 text-xs" style={{ color: "var(--color-ink-3)" }}>
        In development. Not reviewed by a human developer. Do not use with real
        customer data.
      </p>
    </div>
  );
}
