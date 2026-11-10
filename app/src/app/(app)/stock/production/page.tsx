import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { UpgradeNote } from "../../upgrade-note";
import { ProductionBoard, type Recipe, type PlanRow, type RunRow } from "./production-board";

export default async function ProductionPage() {
  const user = await requireUser();
  const canManage = can(user, "stock.manage");
  if (!canManage && !can(user, "stock.view")) {
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
  const [{ data: ings }, { data: boms }, { data: bomLines }, { data: runs }] = await Promise.all([
    supabase.from("ingredients").select("id, name, unit, cost_per_unit, is_active, item_type").order("name"),
    supabase.from("production_boms").select("id, output_ingredient_id, yield_qty, note"),
    supabase.from("production_bom_lines").select("bom_id, ingredient_id, qty"),
    supabase.from("production_runs").select("id, number, output_ingredient_id, planned_qty, planned_for, produced_qty, produced_on, status, value, note").order("created_at", { ascending: false }).limit(40),
  ]);
  const all = ings ?? [];
  const meta = Object.fromEntries(all.map((i) => [i.id, { name: i.name, unit: i.unit, cost: Number(i.cost_per_unit) }]));
  const ingredients = all.filter((i) => i.is_active && i.item_type !== "general").map((i) => ({ id: i.id, name: i.name, unit: i.unit, cost: Number(i.cost_per_unit) }));
  const recipes: Recipe[] = (boms ?? [])
    .map((b) => ({
      outputId: b.output_ingredient_id,
      name: meta[b.output_ingredient_id]?.name ?? "Item",
      unit: meta[b.output_ingredient_id]?.unit ?? "",
      yieldQty: Number(b.yield_qty),
      note: b.note,
      lines: (bomLines ?? [])
        .filter((l) => l.bom_id === b.id)
        .map((l) => ({ ingredient_id: l.ingredient_id, name: meta[l.ingredient_id]?.name ?? "Ingredient", unit: meta[l.ingredient_id]?.unit ?? "", cost: meta[l.ingredient_id]?.cost ?? 0, qty: Number(l.qty) })),
    }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const plans: PlanRow[] = (runs ?? [])
    .filter((r) => r.status === "planned")
    .map((r) => ({ id: r.id, number: r.number, outputId: r.output_ingredient_id, name: meta[r.output_ingredient_id]?.name ?? "Item", unit: meta[r.output_ingredient_id]?.unit ?? "", qty: Number(r.planned_qty), forDate: r.planned_for, note: r.note }))
    .sort((a, b) => a.forDate.localeCompare(b.forDate));
  const done: RunRow[] = (runs ?? [])
    .filter((r) => r.status === "produced")
    .map((r) => ({ id: r.id, number: r.number, name: meta[r.output_ingredient_id]?.name ?? "Item", unit: meta[r.output_ingredient_id]?.unit ?? "", qty: Number(r.produced_qty ?? 0), day: r.produced_on ?? "", value: Number(r.value) }));
  return (
    <div className="mx-auto max-w-4xl">
      <Link href="/stock" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← Stock
      </Link>
      <h1 className="mt-2 text-xl font-bold tracking-tight">Production · {user.branch_name}</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Make a prepared item (a gravy, a batter, a masala) from other ingredients. Making a batch takes the ingredients off the shelf and puts the prepared item on it,
        priced at what the batch cost. Add the prepared item as an ingredient in Stock first, then give it a recipe here.
      </p>
      <ProductionBoard
        canManage={canManage}
        currency={user.currency_code}
        ingredients={ingredients}
        recipes={recipes}
        plans={plans}
        done={done}
      />
    </div>
  );
}
