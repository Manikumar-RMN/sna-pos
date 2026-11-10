import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../upgrade-note";
import { RequestsBoard, type ReqRow } from "./requests-board";

export default async function MaterialRequestsPage() {
  const user = await requireUser();
  const canManage = can(user, "stock.manage");
  if (!canManage && !can(user, "stock.view") && !can(user, "stock.adjust")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock. An owner can give the &ldquo;See stock, costs and stock reports&rdquo; right in Settings → Security profiles.
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
  const [{ data: ings }, { data: reqs }, { data: lines }, { data: issues }, { data: deptRows }] = await Promise.all([
    supabase.from("ingredients").select("id, name, unit, is_active").order("name"),
    supabase.from("material_requests").select("id, number, department, status, note, created_at, reject_reason, requested_by").order("created_at", { ascending: false }).limit(40),
    supabase.from("material_request_lines").select("request_id, ingredient_id, qty, issued_qty"),
    supabase.from("material_issues").select("id, number, department, issued_on, value, note").order("created_at", { ascending: false }).limit(15),
    supabase.from("stock_lists").select("name").eq("kind", "department").eq("is_active", true).order("name"),
  ]);
  const ingredients = (ings ?? []).filter((i) => i.is_active).map((i) => ({ id: i.id, name: i.name, unit: i.unit }));
  const meta: Record<string, { name: string; unit: string }> = Object.fromEntries((ings ?? []).map((i) => [i.id, { name: i.name, unit: i.unit }]));
  const rows: ReqRow[] = (reqs ?? []).map((r) => ({
    id: r.id,
    number: r.number,
    department: r.department,
    status: r.status,
    note: r.note,
    rejectReason: r.reject_reason,
    createdAt: r.created_at,
    lines: (lines ?? [])
      .filter((l) => l.request_id === r.id)
      .map((l) => ({ ingredient_id: l.ingredient_id, name: meta[l.ingredient_id]?.name ?? "Ingredient", unit: meta[l.ingredient_id]?.unit ?? "", qty: Number(l.qty), issued: Number(l.issued_qty) })),
  }));
  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/stock" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← Stock
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Stock requests and issues · {user.branch_name}</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        The kitchen or bar asks for stock here. A manager issues it in full or in part, or turns it down. Issued stock leaves the shelf at today&rsquo;s cost.
      </p>
      <RequestsBoard
        canManage={canManage}
        canBackdate={can(user, "stock.backdate")}
        currency={user.currency_code}
        ingredients={ingredients}
        requests={rows}
        departments={(deptRows ?? []).map((d) => d.name)}
        issues={(issues ?? []).map((i) => ({ id: i.id, number: i.number, department: i.department, issuedOn: i.issued_on, value: Number(i.value), note: i.note }))}
      />
    </div>
  );
}
