import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../upgrade-note";
import { ClosingBoard, type ClosureRow } from "./closing-board";
import { DayClosing } from "./day-closing";

export default async function ClosingPage() {
  const user = await requireUser();
  const canManage = can(user, "stock.manage");
  if (!canManage && !can(user, "stock.view")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock. An owner can change this in Settings → Security profiles.
      </div>
    );
  }
  if (!has(user, "stock")) {
    return (
      <div className="mx-auto max-w-md">
        <UpgradeNote feature="Stock and recipes" />
      </div>
    );
  }
  const supabase = await createClient();
  const [{ data: ings }, { data: mv }, { data: cl }, { data: lines }, { data: dc }] = await Promise.all([
    supabase.from("ingredients").select("id, name, unit, cost_per_unit, is_active").order("name"),
    supabase.from("stock_movements").select("ingredient_id, created_at").order("created_at", { ascending: true }).limit(5000),
    supabase.from("stock_month_closures").select("id, month, total_value, closed_at, revoked_at, revoke_reason").order("month", { ascending: false }).limit(36),
    supabase.from("stock_closure_lines").select("closure_id, ingredient_id, closing_qty, value"),
    supabase.from("stock_day_closures").select("id, day, closed_at, revoked_at, revoke_reason").is("revoked_at", null).order("day", { ascending: false }).limit(60),
  ]);
  const yesterday = new Date(Date.now() - 86400000).toLocaleDateString("en-CA", { timeZone: user.timezone });
  const hasMoves = new Set((mv ?? []).map((m) => m.ingredient_id));
  const first = mv && mv.length > 0 ? mv[0].created_at.slice(0, 7) : null;
  const meta: Record<string, { name: string; unit: string }> = Object.fromEntries((ings ?? []).map((i) => [i.id, { name: i.name, unit: i.unit }]));
  const closures: ClosureRow[] = (cl ?? []).map((c) => ({
    id: c.id,
    month: c.month,
    total: Number(c.total_value),
    closedAt: c.closed_at,
    revoked: !!c.revoked_at,
    revokeReason: c.revoke_reason,
    lines: (lines ?? []).filter((l) => l.closure_id === c.id).map((l) => ({ name: meta[l.ingredient_id]?.name ?? "Ingredient", unit: meta[l.ingredient_id]?.unit ?? "", qty: Number(l.closing_qty), value: Number(l.value) })).filter((l) => l.qty !== 0),
  }));
  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/stock" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← Stock
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Opening stock and month closing · {user.branch_name}</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Enter the stock you start with, once. At the end of a month, close it to save the closing stock and lock that month's receipts.
      </p>
      <ClosingBoard
        canManage={canManage}
        isOwner={can(user, "settings.manage")}
        currency={user.currency_code}
        firstMonth={first}
        ingredients={(ings ?? []).filter((i) => i.is_active && !hasMoves.has(i.id)).map((i) => ({ id: i.id, name: i.name, unit: i.unit, cost: Number(i.cost_per_unit) }))}
        closures={closures}
      />
      <DayClosing canManage={canManage} isOwner={can(user, "settings.manage")} yesterday={yesterday} days={(dc ?? []).map((d) => ({ id: d.id, day: d.day, closedAt: d.closed_at, revoked: !!d.revoked_at, reason: d.revoke_reason }))} />
    </div>
  );
}
