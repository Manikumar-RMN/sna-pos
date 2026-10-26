import { createClient } from "@/lib/supabase/server";
import type { MenuItem, OptionGroup } from "./pos-terminal";

/**
 * The menu as the billing screen and the captain app sell it: dishes on sale now (with today's offer price),
 * each with its option groups, its sizes and its combo mark. RLS scopes every query to the signed-in restaurant.
 */
export async function loadMenu(): Promise<MenuItem[]> {
  const supabase = await createClient();
  const [{ data: menu }, { data: links }, { data: optGroups }, { data: optItems }, { data: sizeRows }, { data: coded }, { data: batchLeft }, { data: liquorGroups }] = await Promise.all([
    supabase
      .from("v_menu")
      .select("id, name, short_name, price, category_id, category_name, category_order, is_veg, display_order, is_available, name_local, parent_id, variant_name, is_combo, list_price, tax_group_id")
      .eq("is_available", true)
      .order("category_order")
      .order("display_order")
      .order("name"),
    supabase.from("product_modifier_groups").select("product_id, modifier_group_id"),
    supabase.from("modifier_groups").select("id, name, min_select, max_select, is_required, is_active").eq("is_active", true),
    supabase.from("modifier_items").select("id, modifier_group_id, name, price_delta, display_order, product_id").eq("is_active", true).order("display_order").order("name"),
    // Dishes that have sizes (even sold-out ones): such a dish is sold only through one of its sizes.
    supabase.from("products").select("parent_id").not("parent_id", "is", null).is("deleted_at", null),
    // Dishes sold by weight, item codes for the barcode scanner / weighing-scale labels, open-priced dishes (price typed at the till),
    // and dishes marked "Do not allow discounts" (they take no share of a bill discount).
    supabase
      .from("products")
      .select("id, sold_by, barcode, is_open_price, discount_restricted")
      .is("deleted_at", null)
      .or("sold_by.eq.weight,barcode.not.is.null,is_open_price.eq.true,discount_restricted.eq.true"),
    // Dishes counted in batches: how many are left today at this outlet.
    supabase.rpc("batch_stock"),
    // Bars: tax groups whose dishes go on separate liquor bills.
    supabase.from("tax_groups").select("id").eq("separate_bill", true),
  ]);
  const liquorIds = new Set((liquorGroups ?? []).map((g) => g.id));
  const left = (batchLeft ?? {}) as Record<string, number>;
  const codeOf = new Map((coded ?? []).map((p) => [p.id, p]));
  // A size follows its dish (the database keeps them in step); if either is marked, the line is not discountable.
  const noDiscount = (id: string, parentId: string | null) => !!codeOf.get(id)?.discount_restricted || (!!parentId && !!codeOf.get(parentId)?.discount_restricted);

  const onSale = new Set((menu ?? []).map((x) => x.id as string));
  // Option groups per menu item, in the order the kitchen expects: required choices first.
  const groupById = new Map(
    (optGroups ?? []).map((g) => {
      const min = Math.max(g.min_select ?? 0, g.is_required ? 1 : 0);
      const group: OptionGroup = {
        id: g.id,
        name: g.name,
        min,
        max: Math.max(g.max_select ?? 1, min, 1),
        options: (optItems ?? [])
          // A combo choice that is a dish shows only while that dish is on sale (not sold out).
          .filter((i) => i.modifier_group_id === g.id && (!i.product_id || onSale.has(i.product_id)))
          .map((i) => ({ id: i.id, name: i.name, price: Number(i.price_delta ?? 0) })),
      };
      return [g.id, group];
    }),
  );
  const groupsFor = (productId: string) =>
    (links ?? [])
      .filter((l) => l.product_id === productId)
      .map((l) => groupById.get(l.modifier_group_id))
      .filter((g): g is OptionGroup => !!g && g.options.length > 0)
      .sort((a, b) => b.min - a.min || a.name.localeCompare(b.name));

  const hasSizes = new Set((sizeRows ?? []).map((r) => r.parent_id as string));
  const live = (menu ?? []).filter((x) => x.id && x.name && x.category_id);
  // The sizes on sale for each dish, cheapest first.
  const sizesFor = (dishId: string) =>
    live
      .filter((x) => x.parent_id === dishId)
      .map((x) => ({ id: x.id as string, name: (x.variant_name ?? x.name) as string, price: Number(x.price) }))
      .sort((a, b) => a.price - b.price || a.name.localeCompare(b.name));
  return (
    live
      // A dish with sizes, all of them sold out, is not on sale.
      .filter((x) => !hasSizes.has(x.id as string) || sizesFor(x.id as string).length > 0)
      .map((x) => ({
        id: x.id as string,
        name: x.name as string,
        short_name: x.short_name,
        price: Number(x.price),
        category_id: x.category_id as string,
        category_name: x.category_name ?? "",
        is_veg: x.is_veg,
        groups: groupsFor(x.id as string),
        name_local: x.name_local,
        /** Set on a size: the dish it belongs to. Sizes are not shown as cards of their own. */
        variantOf: (x.parent_id as string | null) ?? null,
        /** Set on a dish that has sizes: tapping it asks which size. */
        variants: hasSizes.has(x.id as string) ? sizesFor(x.id as string) : undefined,
        /** A combo / meal deal: shown with a "combo" mark. */
        isCombo: !!x.is_combo,
        /** The normal price while a happy hour / offer lowers it now. */
        listPrice: x.list_price != null && Number(x.list_price) > Number(x.price) ? Number(x.list_price) : undefined,
        /** Sold by weight: price is per kg; the bill asks for the weight. */
        byWeight: codeOf.get(x.id as string)?.sold_by === "weight" || undefined,
        /** Item code: scanning it (or a scale label carrying it) adds this dish. */
        barcode: codeOf.get(x.id as string)?.barcode ?? undefined,
        /** Open price: the price is typed at the till (needs the order.open_price right and the internet). */
        is_open_price: codeOf.get(x.id as string)?.is_open_price || undefined,
        /** Counted in batches: how many are left today. */
        left: (x.id as string) in left ? Number(left[x.id as string]) : undefined,
        /** Bars: liquor, billed only on separate liquor bills. */
        liquor: (x.tax_group_id != null && liquorIds.has(x.tax_group_id as string)) || undefined,
        /** Marked "Do not allow discounts": takes no share of a bill discount. */
        no_discount: noDiscount(x.id as string, (x.parent_id as string | null) ?? null) || undefined,
      }))
  );
}

/** Sub-category id → its main category, for the category tabs. */
export async function subCategoryParents(): Promise<Record<string, { id: string; name: string }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.from("categories").select("id, name, parent_id").is("deleted_at", null);
  if (error || !data) return {};
  const names = new Map(data.map((c) => [c.id, c.name]));
  const out: Record<string, { id: string; name: string }> = {};
  for (const c of data) if (c.parent_id && names.has(c.parent_id)) out[c.id] = { id: c.parent_id, name: names.get(c.parent_id)! };
  return out;
}

/** Category id (main or sub) → its brand, when the restaurant runs several brands or stalls. */
export async function categoryBrands(): Promise<Record<string, { id: string; name: string }>> {
  const supabase = await createClient();
  const [{ data: cats }, { data: brands }] = await Promise.all([
    supabase.from("categories").select("id, brand_id").is("deleted_at", null).not("brand_id", "is", null),
    supabase.from("brands").select("id, name").eq("is_active", true),
  ]);
  if (!cats || !brands || brands.length === 0) return {};
  const names = new Map(brands.map((b) => [b.id, b.name]));
  const out: Record<string, { id: string; name: string }> = {};
  for (const c of cats) if (c.brand_id && names.has(c.brand_id)) out[c.id] = { id: c.brand_id, name: names.get(c.brand_id)! };
  return out;
}
