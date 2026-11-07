import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { dateTime, money, todayIn } from "@/lib/format";
import { modulesFor } from "../modules";
import { fmtQty, parseLowStock, STATUS_LABEL } from "@/lib/stock";

type Summary = { bills: number; total_billed: number; average_bill: number; net_collected: number };

export default async function DashboardPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const today = todayIn(user.timezone);
  const posOn = has(user, "pos");
  const canSales = can(user, "report.view_sales") && posOn;
  const canStock = (can(user, "stock.view") || can(user, "stock.manage")) && has(user, "stock");

  const [report, shift, unpaid, kitchen, rest, products, staff, shiftsEver, tables, settings, billsEver, country, lowRes] = await Promise.all([
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
    // Stock running low at this outlet. Empty when the module is off; a failed call just hides the card.
    canStock ? supabase.rpc("low_stock_items", { p_limit: 5 }) : Promise.resolve({ data: null, error: null }),
  ]);
  const lowStock = lowRes.error ? null : parseLowStock(lowRes.data);
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
  const remaining = posOn ? checklist.filter((x) => !x.done) : [];

  return (
    <div className="mx-auto max-w-4xl">
      <div className="mb-5 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold tracking-tight">{user.trading_name}</h1>
          <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Hello {user.full_name.split(" ")[0]} · {user.role_name}
          </p>
        </div>
        {posOn && can(user, "order.create") && (
          <Link href="/pos" className="btn btn-primary">
            Open billing
          </Link>
        )}
      </div>

      <div className="mb-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {modulesFor(user).map((m) => (
          <Link key={m.key} href={m.href} className="card block p-4">
            <p className="text-base font-bold">{m.title}</p>
            <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>{m.blurb}</p>
          </Link>
        ))}
      </div>

      {canSales && s && (
        <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Tile label="Sales today" value={money(s.total_billed, c)} strong />
          <Tile label="Bills today" value={String(s.bills)} />
          <Tile label="Average bill" value={money(s.average_bill, c)} />
          <Tile label="Net sales (after refunds)" value={money(s.net_collected, c)} />
        </div>
      )}

      {posOn && (
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
      )}

      {canStock && lowStock && (lowStock.items.length > 0 || lowStock.out + lowStock.low + lowStock.negative > 0) && (
        <Link href="/stock?filter=low" className="card mb-4 block p-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Low stock
            </div>
            <div className="text-xs font-semibold" style={{ color: "var(--color-warn)" }}>
              {[
                lowStock.negative > 0 ? `${lowStock.negative} below zero` : "",
                lowStock.out > 0 ? `${lowStock.out} out` : "",
                lowStock.low > 0 ? `${lowStock.low} low` : "",
              ]
                .filter(Boolean)
                .join(" · ")}
            </div>
          </div>
          <ul className="mt-2 space-y-1 text-sm">
            {lowStock.items.map((i) => (
              <li key={i.id || i.name} className="flex items-center justify-between gap-3">
                <span className="min-w-0 truncate">{i.name}</span>
                <span className="shrink-0 tabular-nums font-semibold" style={{ color: i.status === "low" ? "var(--color-warn)" : "var(--color-bad)" }}>
                  {fmtQty(i.on_hand)} {i.unit} · {STATUS_LABEL[i.status]}
                </span>
              </li>
            ))}
          </ul>
        </Link>
      )}

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
