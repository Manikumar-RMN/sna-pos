import { can, has, requireUser } from "@/lib/auth";
import { UpgradeNote } from "../upgrade-note";
import { createClient } from "@/lib/supabase/server";
import { todayIn, addDays } from "@/lib/format";
import { StockManager, type Level, type FoodCost } from "./stock-manager";
import { TransferForm } from "./transfer-form";

export default async function StockPage() {
  const user = await requireUser();
  if (!can(user, "stock.manage")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock. An owner can give the &ldquo;Manage stock&rdquo; right in Settings → Security profiles.
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
  const today = todayIn(user.timezone);
  const from = addDays(today, -6);
  const transfers = has(user, "central_kitchen") && user.outlet_count > 1;
  const [{ data: report }, { data: products }, { data: recipes }, { data: others }] = await Promise.all([
    supabase.rpc("stock_report", { p_from: from, p_to: today }),
    supabase.from("products").select("id, name, price").is("deleted_at", null).order("name"),
    supabase.from("recipe_lines").select("product_id, ingredient_id, qty"),
    transfers
      ? supabase.from("branches").select("id, name").is("deleted_at", null).neq("id", user.branch_id).order("created_at")
      : Promise.resolve({ data: [] as { id: string; name: string }[] }),
  ]);
  const rep = (report ?? { levels: [], food_cost: [] }) as unknown as { levels: Level[]; food_cost: FoodCost[] };
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
        levels={rep.levels}
        foodCost={rep.food_cost}
        products={(products ?? []).map((p) => ({ id: p.id, name: p.name, price: Number(p.price) }))}
        recipes={(recipes ?? []).map((r) => ({ product_id: r.product_id, ingredient_id: r.ingredient_id, qty: Number(r.qty) }))}
      />
    </div>
  );
}
