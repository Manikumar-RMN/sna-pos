"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";

export type MenuState = { error: string | null; ok?: boolean };

/**
 * Menu editing is gated here, at the action layer, on the `menu.manage`
 * permission. Row Level Security still guarantees a user can only ever touch
 * their own restaurant's rows; this adds the per-role rule on top, so a
 * Cashier (who has no menu.manage) cannot add or change menu items.
 *
 * The billing-critical rules (void, discount, price change mid-sale) get
 * stronger database-level enforcement in the billing stage; menu CRUD is
 * enforced here.
 */
async function requireMenuManager() {
  const user = await getCurrentUser();
  if (!user) return { user: null, restaurantId: null, denied: "Not signed in." };
  if (!can(user, "menu.manage")) {
    return { user, restaurantId: user.restaurant_id, denied: "You do not have permission to edit the menu." };
  }
  return { user, restaurantId: user.restaurant_id, denied: null as string | null };
}

/* ---------- categories ---------- */

export async function createCategory(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { restaurantId, denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { error: "Enter a category name." };
  // Optional: the main category this one goes inside (a sub-category).
  const parentId = String(formData.get("parent_id") ?? "").trim() || null;

  const supabase = await createClient();
  // New categories go to the end of the menu (the charges category stays last at 999).
  const { data: last } = await supabase
    .from("categories")
    .select("display_order")
    .is("deleted_at", null)
    .lt("display_order", 999)
    .order("display_order", { ascending: false })
    .limit(1)
    .maybeSingle();
  const { error } = await supabase.from("categories").insert({
    restaurant_id: restaurantId!,
    name,
    display_order: Math.min((last?.display_order ?? 0) + 1, 998),
    ...(parentId ? { parent_id: parentId } : {}),
  });
  if (error) {
    return {
      error:
        error.code === "23505"
          ? parentId
            ? "That main category already has a sub-category with this name."
            : "A category with that name already exists."
          : error.message,
    };
  }
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  return { error: null, ok: true };
}

export async function renameCategory(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const id = String(formData.get("id") ?? "");
  const name = String(formData.get("name") ?? "").trim();
  if (!id || !name) return { error: "Enter a category name." };

  // The form only carries "parent_id" when the category may move: "" = make it a main category.
  const moves = formData.has("parent_id");
  const parentId = String(formData.get("parent_id") ?? "").trim() || null;
  if (moves && parentId === id) return { error: "A category cannot go inside itself." };

  const supabase = await createClient();
  const { error } = await supabase
    .from("categories")
    .update(moves ? { name, parent_id: parentId } : { name })
    .eq("id", id);
  if (error) return { error: error.code === "23505" ? "There is already a category with this name in that place." : error.message };
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  return { error: null, ok: true };
}

export async function deleteCategory(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const id = String(formData.get("id") ?? "");
  if (!id) return { error: "Missing category." };

  const supabase = await createClient();

  // A category cannot be removed while it still has active items — otherwise
  // those items would be stranded. The owner empties or moves them first.
  const { count } = await supabase
    .from("products")
    .select("id", { count: "exact", head: true })
    .eq("category_id", id)
    .is("deleted_at", null);
  if ((count ?? 0) > 0) {
    return { error: "This category still has items. Move or remove them first." };
  }

  const { error } = await supabase
    .from("categories")
    .update({ deleted_at: new Date().toISOString() })
    .eq("id", id);
  if (error) return { error: error.message };
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  return { error: null, ok: true };
}

/* ---------- products ---------- */

function parseRupees(raw: string): number | null {
  const n = Number(String(raw).replace(/[^0-9.]/g, ""));
  if (!Number.isFinite(n) || n < 0) return null;
  return Math.round(n * 100) / 100; // 2 dp; stored as numeric(14,2) in rupees
}

/**
 * India: the optional HSN / SAC code on a dish. `undefined` means the form did
 * not carry the field (other countries), so the stored value is left alone.
 */
function parseHsn(formData: FormData, countryCode: string | undefined): { value: string | null | undefined; error: string | null } {
  if (countryCode !== "IN" || !formData.has("hsn_code")) return { value: undefined, error: null };
  const raw = String(formData.get("hsn_code") ?? "").replace(/\s+/g, "");
  if (raw === "") return { value: null, error: null };
  if (!/^[0-9]{4,8}$/.test(raw)) return { value: undefined, error: "The HSN / SAC code is 4 to 8 digits. Leave it empty if you do not have one." };
  return { value: raw, error: null };
}

export async function createProduct(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { user, restaurantId, denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const name = String(formData.get("name") ?? "").trim();
  const categoryId = String(formData.get("category_id") ?? "");
  const taxGroupId = String(formData.get("tax_group_id") ?? "");
  const price = parseRupees(String(formData.get("price") ?? ""));
  const isVeg = formData.get("is_veg") === "on" ? true : formData.get("is_veg") === "off" ? false : null;
  const isCombo = formData.get("is_combo") === "on";
  const station = String(formData.get("kitchen_station") ?? "").trim().slice(0, 30) || null;
  const nameLocal = String(formData.get("name_local") ?? "").trim().slice(0, 120) || null;
  const soldBy = formData.get("sold_by") === "weight" ? "weight" : "unit";
  const barcode = String(formData.get("barcode") ?? "").replace(/\s/g, "").slice(0, 20) || null;
  if (barcode && !/^[0-9A-Za-z-]{1,20}$/.test(barcode)) return { error: "The item code can have only letters, digits and -." };

  if (!name) return { error: "Enter an item name." };
  if (!categoryId) return { error: "Choose a category." };
  if (!taxGroupId) return { error: "Choose a tax group." };
  if (price === null) return { error: "Enter a valid price." };
  const hsn = parseHsn(formData, user?.country_code);
  if (hsn.error) return { error: hsn.error };

  const supabase = await createClient();
  const { data: created, error } = await supabase
    .from("products")
    .insert({
      restaurant_id: restaurantId!,
      category_id: categoryId,
      tax_group_id: taxGroupId,
      name,
      price,
      is_veg: isVeg,
      is_combo: isCombo,
      kitchen_station: station,
      name_local: nameLocal,
      sold_by: soldBy,
      barcode,
      ...(hsn.value !== undefined ? { hsn_code: hsn.value } : {}),
    })
    .select("id")
    .single();
  if (error) return { error: /products_barcode_uq/.test(error.message) ? "Another dish already has that item code." : error.message };
  const linkError = await linkOptionGroups(created.id, restaurantId!, formData);
  if (linkError) return { error: linkError };
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  revalidatePath("/pos");
  return { error: null, ok: true };
}

/** Replaces the option groups attached to an item with the ticked ones in the form. */
async function linkOptionGroups(productId: string, restaurantId: string, formData: FormData): Promise<string | null> {
  if (formData.get("options_present") !== "1") return null;
  const groupIds = formData.getAll("option_group").map(String).filter(Boolean);
  const supabase = await createClient();
  const { error: delError } = await supabase.from("product_modifier_groups").delete().eq("product_id", productId);
  if (delError) return delError.message;
  if (groupIds.length === 0) return null;
  const { error } = await supabase
    .from("product_modifier_groups")
    .insert(groupIds.map((g) => ({ product_id: productId, modifier_group_id: g, restaurant_id: restaurantId })));
  return error ? error.message : null;
}

export async function updateProduct(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { user, restaurantId, denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const id = String(formData.get("id") ?? "");
  const name = String(formData.get("name") ?? "").trim();
  const categoryId = String(formData.get("category_id") ?? "");
  const taxGroupId = String(formData.get("tax_group_id") ?? "");
  const price = parseRupees(String(formData.get("price") ?? ""));
  const isVeg = formData.get("is_veg") === "on" ? true : formData.get("is_veg") === "off" ? false : null;
  const isCombo = formData.get("is_combo") === "on";
  const station = String(formData.get("kitchen_station") ?? "").trim().slice(0, 30) || null;
  const nameLocal = String(formData.get("name_local") ?? "").trim().slice(0, 120) || null;
  const soldBy = formData.get("sold_by") === "weight" ? "weight" : "unit";
  const barcode = String(formData.get("barcode") ?? "").replace(/\s/g, "").slice(0, 20) || null;
  if (barcode && !/^[0-9A-Za-z-]{1,20}$/.test(barcode)) return { error: "The item code can have only letters, digits and -." };

  if (!id) return { error: "Missing item." };
  if (!name) return { error: "Enter an item name." };
  if (!categoryId) return { error: "Choose a category." };
  if (!taxGroupId) return { error: "Choose a tax group." };
  if (price === null) return { error: "Enter a valid price." };
  const hsn = parseHsn(formData, user?.country_code);
  if (hsn.error) return { error: hsn.error };

  const supabase = await createClient();
  const { error } = await supabase
    .from("products")
    .update({
      name,
      name_local: nameLocal,
      sold_by: soldBy,
      barcode,
      category_id: categoryId,
      tax_group_id: taxGroupId,
      price,
      is_veg: isVeg,
      is_combo: isCombo,
      kitchen_station: station,
      ...(hsn.value !== undefined ? { hsn_code: hsn.value } : {}),
    })
    .eq("id", id);
  if (error) return { error: /products_barcode_uq/.test(error.message) ? "Another dish already has that item code." : error.message };
  // The dish's sizes share its tax group, veg mark, kitchen station and HSN code.
  const { error: sizeError } = await supabase
    .from("products")
    .update({
      tax_group_id: taxGroupId,
      is_veg: isVeg,
      kitchen_station: station,
      ...(hsn.value !== undefined ? { hsn_code: hsn.value } : {}),
    })
    .eq("parent_id", id)
    .is("deleted_at", null);
  if (sizeError) return { error: sizeError.message };
  const linkError = await linkOptionGroups(id, restaurantId!, formData);
  if (linkError) return { error: linkError };
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  revalidatePath("/pos");
  return { error: null, ok: true };
}

/* ---------- sizes (variants) ---------- */

/**
 * Adds a size to a dish (Small, Large, Half, Full…). The size is a dish of its own named
 * "<dish> (<size>)" with its own price; it takes the dish's category, tax group, veg mark,
 * kitchen station, HSN code and options. The database names it and keeps it with its dish.
 */
export async function addSize(parentId: string, sizeName: string, rawPrice: string): Promise<MenuState> {
  const { restaurantId, denied } = await requireMenuManager();
  if (denied) return { error: denied };
  const name = sizeName.trim().slice(0, 30);
  const price = parseRupees(rawPrice);
  if (!name) return { error: "Enter the size, for example Large or Half." };
  if (price === null || rawPrice.trim() === "") return { error: "Enter the price for this size." };
  const supabase = await createClient();
  const { data: parent, error: readError } = await supabase
    .from("products")
    .select("id, name, category_id, tax_group_id, is_veg, kitchen_station, hsn_code, parent_id")
    .eq("id", parentId)
    .is("deleted_at", null)
    .maybeSingle();
  if (readError) return { error: readError.message };
  if (!parent) return { error: "That dish was not found." };
  if (parent.parent_id) return { error: "A size cannot have sizes of its own." };
  const { error } = await supabase.from("products").insert({
    restaurant_id: restaurantId!,
    category_id: parent.category_id,
    tax_group_id: parent.tax_group_id,
    is_veg: parent.is_veg,
    kitchen_station: parent.kitchen_station,
    hsn_code: parent.hsn_code,
    name: `${parent.name} (${name})`,
    price,
    parent_id: parent.id,
    variant_name: name,
  });
  if (error) return { error: /duplicate|unique/i.test(error.message) ? `${parent.name} already has the size ${name}.` : error.message };
  revalidatePath("/settings/menu");
  revalidatePath("/pos");
  return { error: null, ok: true };
}

/** Renames a size or changes its price. */
export async function updateSize(id: string, sizeName: string, rawPrice: string): Promise<MenuState> {
  const { denied } = await requireMenuManager();
  if (denied) return { error: denied };
  const name = sizeName.trim().slice(0, 30);
  const price = parseRupees(rawPrice);
  if (!name) return { error: "Enter the size." };
  if (price === null || rawPrice.trim() === "") return { error: "Enter the price for this size." };
  const supabase = await createClient();
  const { error } = await supabase.from("products").update({ variant_name: name, price }).eq("id", id).not("parent_id", "is", null);
  if (error) return { error: /duplicate|unique/i.test(error.message) ? `This dish already has the size ${name}.` : error.message };
  revalidatePath("/settings/menu");
  revalidatePath("/pos");
  return { error: null, ok: true };
}

/* ---------- options & add-ons ---------- */

/** productId: this choice is a dish (a combo choice); its ingredients come out of stock when chosen. */
export type OptionInput = { id: string | null; name: string; price: number; productId?: string | null };

/**
 * Creates or changes an option group (e.g. "Size": Small / Large +20).
 * Removed options are switched off, not deleted, so past bills keep their history.
 */
export async function saveOptionGroup(
  groupId: string | null,
  name: string,
  required: boolean,
  maxChoices: number,
  options: OptionInput[],
): Promise<MenuState> {
  const { restaurantId, denied } = await requireMenuManager();
  if (denied) return { error: denied };
  const groupName = name.trim();
  const clean = options.map((o) => ({ ...o, name: o.name.trim() })).filter((o) => o.name);
  if (!groupName) return { error: "Enter a name for the group, e.g. Size or Add-ons." };
  if (clean.length === 0) return { error: "Add at least one option." };
  if (clean.length > 20) return { error: "A group can have at most 20 options." };
  if (new Set(clean.map((o) => o.name.toLowerCase())).size !== clean.length) return { error: "Two options have the same name." };
  if (clean.some((o) => !Number.isFinite(o.price) || Math.abs(o.price) > 100000)) return { error: "Enter a valid extra price for every option." };
  const max = Math.round(maxChoices);
  if (!(max >= 1 && max <= clean.length)) return { error: `Customers can choose between 1 and ${clean.length} options.` };

  const supabase = await createClient();
  const groupRow = { name: groupName, is_required: required, min_select: required ? 1 : 0, max_select: max, is_active: true };
  let gid = groupId;
  if (gid) {
    const { error } = await supabase.from("modifier_groups").update(groupRow).eq("id", gid);
    if (error) return { error: error.message };
  } else {
    const { data, error } = await supabase
      .from("modifier_groups")
      .insert({ ...groupRow, restaurant_id: restaurantId! })
      .select("id")
      .single();
    if (error) return { error: error.message };
    gid = data.id;
  }

  const { data: existing } = await supabase.from("modifier_items").select("id").eq("modifier_group_id", gid);
  const keep = new Set(clean.map((o) => o.id).filter(Boolean));
  const retire = (existing ?? []).map((e) => e.id).filter((id) => !keep.has(id));
  if (retire.length) {
    const { error } = await supabase.from("modifier_items").update({ is_active: false }).in("id", retire);
    if (error) return { error: error.message };
  }
  for (const [i, o] of clean.entries()) {
    const row = { name: o.name, price_delta: Math.round(o.price * 100) / 100, display_order: i + 1, is_active: true, product_id: o.productId || null };
    const { error } = o.id
      ? await supabase.from("modifier_items").update(row).eq("id", o.id).eq("modifier_group_id", gid)
      : await supabase.from("modifier_items").insert({ ...row, restaurant_id: restaurantId!, modifier_group_id: gid });
    if (error) return { error: error.message };
  }
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  revalidatePath("/pos");
  return { error: null, ok: true };
}

export async function removeOptionGroup(groupId: string): Promise<MenuState> {
  const { denied } = await requireMenuManager();
  if (denied) return { error: denied };
  const supabase = await createClient();
  const { error: linkError } = await supabase.from("product_modifier_groups").delete().eq("modifier_group_id", groupId);
  if (linkError) return { error: linkError.message };
  const { error } = await supabase.from("modifier_groups").update({ is_active: false }).eq("id", groupId);
  if (error) return { error: error.message };
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  revalidatePath("/pos");
  return { error: null, ok: true };
}

export async function toggleAvailability(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const id = String(formData.get("id") ?? "");
  const makeAvailable = String(formData.get("available") ?? "") === "true";

  const supabase = await createClient();
  const { error } = await supabase.from("products").update({ is_available: makeAvailable }).eq("id", id);
  if (error) return { error: error.message };
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  revalidatePath("/pos");
  return { error: null, ok: true };
}

export async function deleteProduct(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const id = String(formData.get("id") ?? "");
  if (!id) return { error: "Missing item." };

  const supabase = await createClient();
  const { error } = await supabase
    .from("products")
    .update({ deleted_at: new Date().toISOString() })
    .eq("id", id);
  if (error) return { error: error.message };
  revalidatePath("/settings/menu");
  revalidatePath("/welcome");
  revalidatePath("/pos");
  return { error: null, ok: true };
}

/* ---------- upload a whole menu sheet ---------- */

export type MenuImportResult =
  | {
      ok: true;
      applied: boolean;
      errors: { row: number; message: string }[];
      newCategories: number;
      newItems: number;
      updatedItems: number;
      unchangedItems: number;
    }
  | { ok: false; error: string };

/**
 * Checks (apply = false) or saves (apply = true) the rows of an uploaded menu sheet.
 * The database checks every row first and saves nothing unless all of them are right.
 */
export async function importMenu(
  rows: { row: number; category: string; sub_category: string; name: string; price: string; tax_group: string; veg: string; hsn: string; station: string; local_name: string }[],
  apply: boolean,
): Promise<MenuImportResult> {
  const { denied } = await requireMenuManager();
  if (denied) return { ok: false, error: denied };
  if (!Array.isArray(rows) || rows.length === 0) return { ok: false, error: "The file has no menu rows." };
  if (rows.length > 2000) return { ok: false, error: "Up to 2,000 rows can be uploaded at once. Split the file." };
  const clean = rows.map((r) => ({
    row: Number(r.row) || 0,
    category: String(r.category ?? "").slice(0, 200),
    sub_category: String(r.sub_category ?? "").slice(0, 200),
    name: String(r.name ?? "").slice(0, 300),
    price: String(r.price ?? "").slice(0, 40),
    tax_group: String(r.tax_group ?? "").slice(0, 120),
    veg: String(r.veg ?? "").slice(0, 20),
    hsn: String(r.hsn ?? "").slice(0, 20),
    station: String(r.station ?? "").slice(0, 60),
    local_name: String(r.local_name ?? "").slice(0, 300),
  }));
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("import_menu", { p_rows: clean, p_apply: apply });
  if (error) return { ok: false, error: error.message };
  const v = data as {
    ok: boolean;
    applied: boolean;
    errors: { row: number; message: string }[];
    new_categories: number;
    new_items: number;
    updated_items: number;
    unchanged_items: number;
  };
  if (v.applied) {
    revalidatePath("/settings/menu");
    revalidatePath("/welcome");
    revalidatePath("/pos");
  }
  return {
    ok: true,
    applied: !!v.applied,
    errors: v.errors ?? [],
    newCategories: v.new_categories ?? 0,
    newItems: v.new_items ?? 0,
    updatedItems: v.updated_items ?? 0,
    unchangedItems: v.unchanged_items ?? 0,
  };
}
