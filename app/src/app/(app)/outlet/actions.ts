"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
export type OutletResult = { ok: true; message?: string } | { ok: false; error: string };

/** Switch the outlet this person is working in. "all" shows every outlet in reports. */
export async function switchOutlet(branchId: string, allOutlets: boolean): Promise<OutletResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_current_outlet", { p_branch: branchId, p_all: allOutlets });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/", "layout");
  return { ok: true };
}

export async function setOutletPrice(productId: string, branchId: string, price: string, available: boolean | null): Promise<OutletResult> {
  const value = price.trim() === "" ? null : Number(price);
  if (value !== null && !(Number.isFinite(value) && value >= 0)) return { ok: false, error: "Enter a price, or leave it empty to use the menu price." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_outlet_price", {
    p_product_id: productId,
    p_branch_id: branchId,
    p_price: value as number,
    p_available: available as boolean,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/outlets");
  revalidatePath("/pos");
  return { ok: true, message: "Saved." };
}

export async function setUserOutlets(userId: string, branchIds: string[]): Promise<OutletResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_user_outlets", { p_user_id: userId, p_branches: branchIds });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/outlets");
  return { ok: true, message: "Saved." };
}

export async function setCentralKitchen(branchId: string, on: boolean): Promise<OutletResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_central_kitchen", { p_branch: branchId, p_on: on });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/outlets");
  revalidatePath("/stock");
  return { ok: true, message: "Saved." };
}

export async function transferStock(ingredientId: string, qty: string, toBranch: string, note: string): Promise<OutletResult> {
  const n = Number(qty);
  if (!(n > 0)) return { ok: false, error: "Enter a quantity." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("transfer_stock", { p_ingredient_id: ingredientId, p_qty: n, p_to_branch: toBranch, p_note: note || undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock");
  return { ok: true, message: "Sent." };
}
