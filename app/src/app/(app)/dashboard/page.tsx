import Link from "next/link";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { dateTime, money, todayIn } from "@/lib/format";

type Summary = { bills: number; total_billed: number; average_bill: number; net_collected: number };

export default async function DashboardPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const today = todayIn(user.timezone);
  const canSales = can(user, "report.view_sales");

  const [report, shift, unpaid, kitchen, rest, products, staff, shiftsEver, tables, settings, billsEver, country] = await Promise.all([
    canSales ? supabase.rpc("sales_report", { p_from: today, p_to: today }) : Promise.resolve({ data: null }),
    supabase.from("shifts").select("id, opened_at, opened_by").eq("status", "open").limit(1).maybeSingle(),
    supabase.from("orders").select("id, grand_total, paid_total").in("payment_status", ["unpaid", "partial"]).neq("status", "voided"),
    supabase.from("kitchen_tickets").select("id", { count: "exact", head: true }).in("status", ["new", "preparing"]),
    supabase.from("restaurants").select("tax_registration_no").limit(1).maybeSingle(),
    supabase.from("products").select("id", { count: "exact", head: true }).is("deleted_at", null),
    supabase.from("users").select("id", { count: "exact", head: true }).is("deleted_at", null),
    supabase.from("shifts").select("id", { count: "exact", head: true }),
    supabase.from("dining_tables").select("id", { count: "exact", head: true }).eq("is_active", true).eq("is_kiosk", false),
    supabase.from("branch_settings").select("shifts_enabled").eq("branch_id", user.branch_id).maybeSingle(),
    supabase.from("orders").select("id", { count: "exact", head: true }),
    supabase.from("countries").select("tax_id_label").eq("code", user.country_code).maybeSingle(),
  ]);
  // Shifts are optional (off unless the owner switches them on): without them billing is always open.
  const shiftsOn = !!settings.data?.shifts_enabled;
  const taxIdLabel = country.data?.tax_id_label ?? "tax number";

  const s = (report.data as unknown as { summary: Summary } | null)?.summary;
  const c = user.currency_code;
  const unpaidRows = unpaid.data ?? [];
  const { data: opener } = shift.data?.opened_by
    ? await supabase.from("users").select("full_name").eq("id", shift.data.opened_by).maybeSingle()
    : { data: null };

  const checklist = [
    { done: (products.count ?? 0) > 0, text: "Add your menu", href: "/settings/menu" },
    { done: !!rest.data?.tax_registration_no, text: `Add your ${taxIdLabel} so it prints on bills`, href: "/settings/company" },
    shiftsOn
      ? { done: (shiftsEver.count ?? 0) > 0, text: "Open your first shift", href: "/shift" }
      : { done: (billsEver.count ?? 0) > 0, text: "Make your first bill", href: "/pos" },
    { done: (staff.count ?? 0) > 1, text: "Add your staff (each gets their own sign-in)", href: "/settings/users" },
    { done: (tables.count ?? 0) > 0, text: "Add your tables (optional)", href: "/settings/tables" },
  ];
  const remaining = checklist.filter((x) => !x.done);

  return (
    <div className="mx-auto max-w-4xl">
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold tracking-tight">{user.trading_name}</h1>
          <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Hello {user.full_name.split(" ")[0]} · {user.role_name}
          </p>
        </div>
        {can(user, "order.create") && (
          <Link href="/pos" className="btn btn-primary">
            Open billing
          </Link>
        )}
      </div>

      {canSales && s && (
        <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Tile label="Sales today" value={money(s.total_billed, c)} strong />
          <Tile label="Bills today" value={String(s.bills)} />
          <Tile label="Average bill" value={money(s.average_bill, c)} />
          <Tile label="Net sales (after refunds)" value={money(s.net_collected, c)} />
        </div>
      )}

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        <Link href="/shift" className="card p-4">
          <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
            {shiftsOn ? "Shift" : "Day close"}
          </div>
          {!shiftsOn ? (
            <div className="mt-1 text-sm">
              <span className="font-bold" style={{ color: "var(--color-ok)" }}>
                Billing is open
              </span>{" "}
              · count the cash when you close the day
            </div>
          ) : shift.data ? (
            <div className="mt-1 text-sm">
              <span className="font-bold" style={{ color: "var(--color-ok)" }}>
                Open
              </span>{" "}
              since {dateTime(shift.data.opened_at, user.timezone)}
              {opener?.full_name ? ` · ${opener.full_name}` : ""}
            </div>
          ) : (
            <div className="mt-1 text-sm font-bold" style={{ color: "var(--color-warn)" }}>
              No shift open — billing is paused
            </div>
          )}
        </Link>
        <Link href="/bills?show=unpaid" className="card p-4">
          <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
            Unpaid bills
          </div>
          <div className="mt-1 text-sm">
            <span className="font-bold" style={unpaidRows.length ? { color: "var(--color-warn)" } : undefined}>
              {unpaidRows.length}
            </span>{" "}
            · {money(unpaidRows.reduce((a, o) => a + Number(o.grand_total) - Number(o.paid_total ?? 0), 0), c)}
          </div>
        </Link>
        <Link href="/kitchen" className="card p-4">
          <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
            Kitchen queue
          </div>
          <div className="mt-1 text-sm">
            <span className="font-bold">{kitchen.count ?? 0}</span> ticket{kitchen.count === 1 ? "" : "s"} waiting
          </div>
        </Link>
      </div>

      {remaining.length > 0 && (
        <div className="card p-5">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <h2 className="text-base font-bold">Getting started</h2>
            {can(user, "settings.manage") && (
              <Link href="/welcome" className="btn btn-primary">
                Open the setup guide
              </Link>
            )}
          </div>
          <ul className="mt-3 space-y-2 text-sm">
            {checklist.map((x) => (
              <li key={x.text} className="flex items-center gap-2">
                <span aria-hidden>{x.done ? "✅" : "⬜"}</span>
                {x.done ? (
                  <span style={{ color: "var(--color-ink-3)" }}>{x.text}</span>
                ) : (
                  <Link href={x.href} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                    {x.text}
                  </Link>
                )}
              </li>
            ))}
          </ul>
        </div>
      )}

      <p className="mt-6 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Card and UPI payments are recorded only. No payment gateway is connected.
      </p>
    </div>
  );
}

function Tile({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="card p-4">
      <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
        {label}
      </div>
      <div className="mt-1 text-2xl font-bold tabular-nums" style={strong ? { color: "var(--color-brand-strong)" } : undefined}>
        {value}
      </div>
    </div>
  );
}
