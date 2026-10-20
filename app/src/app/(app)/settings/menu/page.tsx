import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { MenuManager, type OptionGroupView } from "../../menu/menu-manager";
import { MenuUpload } from "./menu-upload";

export default async function MenuPage() {
  const user = await requireUser();
  const supabase = await createClient();

  // RLS scopes all of these to the signed-in user's restaurant.
  const [{ data: categories }, { data: products }, { data: taxGroups }, { data: groups }, { data: optItems }, { data: links }, { data: taxRates }] =
    await Promise.all([
      supabase.from("categories").select("id, name, display_order, parent_id").is("deleted_at", null).order("display_order").order("name"),
      supabase
        .from("products")
        .select("id, name, price, category_id, tax_group_id, is_veg, is_available, kitchen_station, name_local, hsn_code, is_charge, parent_id, variant_name, is_combo, sold_by, barcode, track_batches")
        .is("deleted_at", null)
        .order("name"),
      supabase.from("tax_groups").select("id, name").eq("is_active", true).order("name"),
      supabase.from("modifier_groups").select("id, name, is_required, min_select, max_select").eq("is_active", true).order("name"),
      supabase.from("modifier_items").select("id, modifier_group_id, name, price_delta, display_order, product_id").eq("is_active", true).order("display_order"),
      supabase.from("product_modifier_groups").select("product_id, modifier_group_id"),
      supabase.from("tax_rates").select("tax_group_id, total_rate, valid_from, valid_to"),
    ]);

  // The percentage each tax group charges today, shown next to its name (VAT 22%, Food 5%).
  const today = new Date().toISOString().slice(0, 10);
  const rateOf = new Map<string, { from: string; rate: number }>();
  for (const r of taxRates ?? []) {
    if (r.valid_from > today || (r.valid_to && r.valid_to < today)) continue;
    const cur = rateOf.get(r.tax_group_id);
    if (!cur || r.valid_from > cur.from) rateOf.set(r.tax_group_id, { from: r.valid_from, rate: Number(r.total_rate) });
  }
  const taxGroupsWithRate = (taxGroups ?? []).map((g) => ({ ...g, rate: rateOf.get(g.id)?.rate ?? null }));

  const optionGroups: OptionGroupView[] = (groups ?? []).map((g) => ({
    id: g.id,
    name: g.name,
    required: !!g.is_required || (g.min_select ?? 0) > 0,
    max: g.max_select ?? 1,
    options: (optItems ?? [])
      .filter((i) => i.modifier_group_id === g.id)
      .map((i) => ({ id: i.id, name: i.name, price: Number(i.price_delta ?? 0), productId: i.product_id ?? null })),
  }));
  const productGroups: Record<string, string[]> = {};
  for (const l of links ?? []) (productGroups[l.product_id] ??= []).push(l.modifier_group_id);

  return (
    <div>
      <h2 className="text-xl font-bold">Menu</h2>
      <p className="mt-1 mb-6 text-sm" style={{ color: "var(--color-ink-3)" }}>
        The dishes and prices your restaurant sells. These appear on the billing screen.
      </p>

      {can(user, "menu.manage") && (
        <MenuUpload
          taxGroups={taxGroups ?? []}
          categories={categories ?? []}
          products={(products ?? []).map((p) => ({ ...p, price: Number(p.price) }))}
          showHsn={user.country_code === "IN"}
          showStations={has(user, "kitchen_stations")}
        />
      )}

      <MenuManager
        canManage={can(user, "menu.manage")}
        currency={user.currency_code}
        categories={categories ?? []}
        products={(products ?? []).map((p) => ({ ...p, price: Number(p.price), is_available: p.is_available ?? true }))}
        taxGroups={taxGroupsWithRate}
        optionGroups={optionGroups}
        productGroups={productGroups}
        showStations={has(user, "kitchen_stations")}
        showHsn={user.country_code === "IN"}
      />
    </div>
  );
}
