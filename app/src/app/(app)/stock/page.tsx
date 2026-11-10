import { can, has, requireUser } from "@/lib/auth";
import { UpgradeNote } from "../upgrade-note";
import { createClient } from "@/lib/supabase/server";
import { todayIn, addDays } from "@/lib/format";
import { StockManager, type Level, type FoodCost } from "./stock-manager";
import type { RecentAdjust } from "./wastage-form";
import { TransferForm } from "./transfer-form";

export default async function StockPage({ searchParams }: { searchParams: Promise<{ filter?: string }> }) {
  const user = await requireUser();
  const canManage = can(user, "stock.manage");
  const canAdjust = canManage || can(user, "stock.adjust");
  const canView = canManage || canAdjust || can(user, "stock.view");
  if (!canView) {
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
  const { filter } = await searchParams;
  const supabase = await createClient();
  const today = todayIn(user.timezone);
  const from = addDays(today, -6);
  const transfers = canManage && has(user, "central_kitchen") && user.outlet_count > 1;
  const [{ data: report }, { data: products }, { data: recipes }, { data: others }, recentRes, { data: buyRows }, { data: typeRows }] = await Promise.all([
    supabase.rpc("stock_report", { p_from: from, p_to: today }),
    canManage ? supabase.from("products").select("id, name, price").is("deleted_at", null).order("name") : Promise.resolve({ data: [] as { id: string; name: string; price: number }[] }),
    canManage ? supabase.from("recipe_lines").select("product_id, ingredient_id, qty") : Promise.resolve({ data: [] as { product_id: string; ingredient_id: string; qty: number }[] }),
    transfers
      ? supabase.from("branches").select("id, name").is("deleted_at", null).neq("id", user.branch_id).order("created_at")
      : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    // Latest wastage and manual adjustments of this outlet (needs stock.view or stock.manage to read; empty for an adjust-only role).
    canAdjust
      ? supabase.from("stock_movements").select("id, created_at, ingredient_id, qty, kind, reason, note, ingredients(name, unit)").in("kind", ["wastage", "adjust"]).order("created_at", { ascending: false }).limit(20)
      : Promise.resolve({ data: [], error: null }),
    // Buying units (kg → 1000 g) for the stock-in and ingredient forms.
    supabase.from("ingredients").select("id, purchase_unit, purchase_factor").not("purchase_unit", "is", null),
    // Food or General, merged into each stock row below.
    supabase.from("ingredients").select("id, item_type"),
  ]);
  const rep = (report ?? { levels: [], food_cost: [] }) as unknown as { levels: Level[]; food_cost: FoodCost[] };
  const typeOf = new Map((typeRows ?? []).map((t) => [t.id, t.item_type === "general" ? "general" : "food"] as const));
  rep.levels = rep.levels.map((l) => ({ ...l, item_type: typeOf.get(l.id) ?? "food" }));
  const recent: RecentAdjust[] = ((recentRes.data ?? []) as unknown as Record<string, unknown>[]).map((r) => {
    const ing = (r.ingredients ?? {}) as { name?: string; unit?: string };
    return {
      id: String(r.id),
      at: String(r.created_at),
      ingredient: ing.name ?? "Ingredient",
      unit: ing.unit ?? "",
      qty: Number(r.qty),
      kind: String(r.kind),
      reason: (r.reason as string | null) ?? null,
      note: (r.note as string | null) ?? null,
    };
  });
  return (
    <div className="mx-auto max-w-4xl">
      <h1 className="text-xl font-bold tracking-tight">Stock</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Ingredients are used up as dishes are billed and put back when an item or bill is cancelled. Record purchases, wastage and
        stock counts here. Usage figures are for the last 7 days.
      </p>
      {transfers && (
        <TransferForm
          from={user.branch_name}
          outlets={others ?? []}
          ingredients={rep.levels.map((l) => ({
            id: l.id,
            name: l.name,
            unit: l.unit,
            stock: Number(l.stock),
          }))}
        />
      )}
      <StockManager
        currency={user.currency_code}
        timezone={user.timezone}
        levels={rep.levels}
        foodCost={rep.food_cost}
        products={(products ?? []).map((p) => ({ id: p.id, name: p.name, price: Number(p.price) }))}
        recipes={(recipes ?? []).map((r) => ({ product_id: r.product_id, ingredient_id: r.ingredient_id, qty: Number(r.qty) }))}
        recent={recent}
        buyUnits={Object.fromEntries((buyRows ?? []).filter((b) => b.purchase_unit).map((b) => [b.id, { unit: b.purchase_unit as string, factor: Number(b.purchase_factor) }]))}
        canManage={canManage}
        canAdjust={canAdjust}
        initialFilter={filter === "low" ? "low" : undefined}
      />
    </div>
  );
}
