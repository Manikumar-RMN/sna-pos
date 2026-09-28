import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { todayIn, addDays } from "@/lib/format";
import { StockManager, type Level, type FoodCost } from "./stock-manager";

export default async function StockPage() {
  const user = await requireUser();
  if (!can(user, "stock.manage")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock. An owner can give the &ldquo;Manage stock&rdquo; right in Settings → Security profiles.
      </div>
    );
  }
  const supabase = await createClient();
  const today = todayIn(user.timezone);
  const from = addDays(today, -6);
  const [{ data: report }, { data: products }, { data: recipes }] = await Promise.all([
    supabase.rpc("stock_report", { p_from: from, p_to: today }),
    supabase.from("products").select("id, name, price").is("deleted_at", null).order("name"),
    supabase.from("recipe_lines").select("product_id, ingredient_id, qty"),
  ]);
  const rep = (report ?? { levels: [], food_cost: [] }) as unknown as { levels: Level[]; food_cost: FoodCost[] };
  return (
    <div className="mx-auto max-w-4xl">
      <h1 className="text-xl font-bold tracking-tight">Stock</h1>
      <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Ingredients are used up as dishes are billed and put back when an item or bill is cancelled. Record purchases, wastage and
        stock counts here. Usage figures are for the last 7 days.
      </p>
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
