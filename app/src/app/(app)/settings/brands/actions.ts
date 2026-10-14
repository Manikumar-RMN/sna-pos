"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";

import { friendlyDbError } from "@/lib/db-error";
function clean(message: string) {
  return message.replace(/^.*?ERROR:\s*/i, "").trim();
}

export type BrandInput = { id: string | null; name: string; commission: number; legal_name: string; gstin: string; active: boolean };

/** Adds or changes a brand / stall. The database checks every field. */
export async function saveBrand(b: BrandInput): Promise<{ error: string | null }> {
  const user = await getCurrentUser();
  if (!user || !can(user, "settings.manage")) return { error: "Changing brands needs the “Manage settings” permission." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("brand_save", {
    p_id: (b.id ?? null) as string,
    p_name: b.name,
    p_commission: b.commission,
    p_legal_name: b.legal_name || undefined,
    p_gstin: b.gstin || undefined,
    p_active: b.active,
  });
  if (error) return { error: clean(friendlyDbError(error)) };
  revalidatePath("/settings/brands");
  revalidatePath("/pos");
  return { error: null };
}

/** Puts a main category (and its sub-categories) under a brand, or under none. */
export async function setCategoryBrand(categoryId: string, brandId: string | null): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("category_set_brand", { p_category: categoryId, p_brand: (brandId ?? null) as string });
  if (error) return { error: clean(friendlyDbError(error)) };
  revalidatePath("/settings/brands");
  revalidatePath("/pos");
  return { error: null };
}

export type SettlementRow = {
  brand_id: string | null;
  brand: string;
  gstin: string | null;
  bills: number;
  qty: number;
  sales: number;
  tax: number;
  billed: number;
  commission_percent: number;
  commission: number;
  payable: number;
};

/** Sales, commission and amount payable per brand for a date range. */
export async function brandSettlement(from: string, to: string): Promise<{ error: string | null; rows: SettlementRow[] }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("brand_settlement", { p_from: from, p_to: to });
  if (error) return { error: clean(friendlyDbError(error)), rows: [] };
  return { error: null, rows: ((data as { brands: SettlementRow[] }).brands ?? []).map((r) => ({ ...r, sales: Number(r.sales), tax: Number(r.tax), billed: Number(r.billed), commission: Number(r.commission), payable: Number(r.payable), qty: Number(r.qty) })) };
}
