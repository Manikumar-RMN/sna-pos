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

  const supabase = await createClient();
  const { error } = await supabase.from("categories").insert({
    restaurant_id: restaurantId!,
    name,
  });
  if (error) {
    return { error: error.code === "23505" ? "A category with that name already exists." : error.message };
  }
  revalidatePath("/menu");
  return { error: null, ok: true };
}

export async function renameCategory(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const id = String(formData.get("id") ?? "");
  const name = String(formData.get("name") ?? "").trim();
  if (!id || !name) return { error: "Enter a category name." };

  const supabase = await createClient();
  const { error } = await supabase.from("categories").update({ name }).eq("id", id);
  if (error) return { error: error.message };
  revalidatePath("/menu");
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
  revalidatePath("/menu");
  return { error: null, ok: true };
}

/* ---------- products ---------- */

function parseRupees(raw: string): number | null {
  const n = Number(String(raw).replace(/[^0-9.]/g, ""));
  if (!Number.isFinite(n) || n < 0) return null;
  return Math.round(n * 100) / 100; // 2 dp; stored as numeric(14,2) in rupees
}

export async function createProduct(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { restaurantId, denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const name = String(formData.get("name") ?? "").trim();
  const categoryId = String(formData.get("category_id") ?? "");
  const taxGroupId = String(formData.get("tax_group_id") ?? "");
  const price = parseRupees(String(formData.get("price") ?? ""));
  const isVeg = formData.get("is_veg") === "on" ? true : formData.get("is_veg") === "off" ? false : null;

  if (!name) return { error: "Enter an item name." };
  if (!categoryId) return { error: "Choose a category." };
  if (!taxGroupId) return { error: "Choose a tax group." };
  if (price === null) return { error: "Enter a valid price." };

  const supabase = await createClient();
  const { error } = await supabase.from("products").insert({
    restaurant_id: restaurantId!,
    category_id: categoryId,
    tax_group_id: taxGroupId,
    name,
    price,
    is_veg: isVeg,
  });
  if (error) return { error: error.message };
  revalidatePath("/menu");
  return { error: null, ok: true };
}

export async function updateProduct(_prev: MenuState, formData: FormData): Promise<MenuState> {
  const { denied } = await requireMenuManager();
  if (denied) return { error: denied };

  const id = String(formData.get("id") ?? "");
  const name = String(formData.get("name") ?? "").trim();
  const categoryId = String(formData.get("category_id") ?? "");
  const taxGroupId = String(formData.get("tax_group_id") ?? "");
  const price = parseRupees(String(formData.get("price") ?? ""));
  const isVeg = formData.get("is_veg") === "on" ? true : formData.get("is_veg") === "off" ? false : null;

  if (!id) return { error: "Missing item." };
  if (!name) return { error: "Enter an item name." };
  if (price === null) return { error: "Enter a valid price." };

  const supabase = await createClient();
  const { error } = await supabase
    .from("products")
    .update({ name, category_id: categoryId, tax_group_id: taxGroupId, price, is_veg: isVeg })
    .eq("id", id);
  if (error) return { error: error.message };
  revalidatePath("/menu");
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
  revalidatePath("/menu");
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
  revalidatePath("/menu");
  return { error: null, ok: true };
}
