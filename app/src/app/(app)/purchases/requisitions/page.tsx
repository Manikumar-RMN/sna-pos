import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../upgrade-note";
import { RequisitionBoard, type PrRow } from "./requisition-board";

export default async function RequisitionsPage() {
  const user = await requireUser();
  const canManage = can(user, "stock.manage");
  if (!canManage && !can(user, "stock.view") && !can(user, "stock.adjust")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock or purchases. An owner can change this in Settings → Security profiles.
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
  const [{ data: ings }, { data: reqs }, { data: lines }, { data: sups }, { data: settings }, { data: orders }] = await Promise.all([
    supabase.from("ingredients").select("id, name, unit, cost_per_unit, is_active").order("name"),
    supabase.from("purchase_requisitions").select("id, number, status, note, est_total, created_at, reject_reason, purchase_order_id").order("created_at", { ascending: false }).limit(40),
    supabase.from("requisition_lines").select("requisition_id, ingredient_id, qty, est_cost"),
    canManage ? supabase.from("suppliers").select("id, name").eq("is_active", true).order("name") : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    supabase.from("purchase_settings").select("approval_limit").maybeSingle(),
    supabase.from("purchase_orders").select("id, number").limit(200),
  ]);
  const meta: Record<string, { name: string; unit: string }> = Object.fromEntries((ings ?? []).map((i) => [i.id, { name: i.name, unit: i.unit }]));
  const poNumber: Record<string, string> = Object.fromEntries((orders ?? []).map((o) => [o.id, o.number]));
  const rows: PrRow[] = (reqs ?? []).map((r) => ({
    id: r.id,
    number: r.number,
    status: r.status,
    note: r.note,
    estTotal: Number(r.est_total),
    createdAt: r.created_at,
    rejectReason: r.reject_reason,
    orderNumber: r.purchase_order_id ? (poNumber[r.purchase_order_id] ?? null) : null,
    lines: (lines ?? []).filter((l) => l.requisition_id === r.id).map((l) => ({ name: meta[l.ingredient_id]?.name ?? "Ingredient", unit: meta[l.ingredient_id]?.unit ?? "", qty: Number(l.qty), estCost: Number(l.est_cost) })),
  }));
  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/purchases" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← Purchases
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Purchase requisitions · {user.branch_name}</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Ask to buy something. A manager approves it, then it becomes a purchase order. Costs shown are the current cost of each ingredient, so the total is an estimate.
      </p>
      <RequisitionBoard
        canManage={canManage}
        isOwner={can(user, "settings.manage")}
        currency={user.currency_code}
        limit={settings?.approval_limit == null ? null : Number(settings.approval_limit)}
        ingredients={(ings ?? []).filter((i) => i.is_active).map((i) => ({ id: i.id, name: i.name, unit: i.unit, cost: Number(i.cost_per_unit) }))}
        suppliers={sups ?? []}
        requisitions={rows}
      />
    </div>
  );
}
