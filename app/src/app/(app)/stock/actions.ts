"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import type { Json } from "@/lib/supabase/database.types";

export type StockResult = { ok: true; message?: string } | { ok: false; error: string };

export async function saveIngredient(input: { id: string | null; name: string; unit: string; cost: number; reorder: number }): Promise<StockResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_ingredient", {
    p_id: input.id as string,
    p_name: input.name,
    p_unit: input.unit,
    p_cost: input.cost,
    p_reorder: input.reorder,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/stock");
  return { ok: true, message: input.id ? "Ingredient saved." : `${input.name} added.` };
}

export async function saveRecipe(productId: string, lines: { ingredient_id: string; qty: number }[]): Promise<StockResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_recipe", { p_product_id: productId, p_lines: lines as unknown as Json });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/stock");
  return { ok: true, message: "Recipe saved. Sales now use up these ingredients." };
}

export async function recordStock(input: { ingredientId: string; kind: "purchase" | "wastage" | "count"; qty: number; unitCost: number | null; note: string }): Promise<StockResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("record_stock", {
    p_ingredient_id: input.ingredientId,
    p_kind: input.kind,
    p_qty: input.qty,
    p_unit_cost: input.unitCost ?? undefined,
    p_note: input.note || undefined,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/stock");
  const r = (data ?? {}) as { stock?: number };
  return { ok: true, message: `Saved. Stock now ${Number(r.stock ?? 0).toFixed(2)}.` };
}
