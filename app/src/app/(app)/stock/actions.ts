"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";
import { fmtQty, type AdjustKind, type CountLine, type StockInLine } from "@/lib/stock";

export type StockResult = { ok: true; message?: string } | { ok: false; error: string };

export async function saveIngredient(input: {
  id: string | null;
  name: string;
  unit: string;
  cost: number;
  reorder: number;
  /** The group it belongs to ("Vegetables", "Dairy"…), or "" for none. Always sent: leaving it out would clear the group. */
  category: string;
  /** Buying unit (kg, box…) and how many stock units it holds. Empty unit = bought in the stock unit. */
  purchaseUnit?: string;
  purchaseFactor?: number;
  /** "food" or "general". Left out, an edit keeps its type and a new item is Food. */
  itemType?: "food" | "general";
  /** HSN code, 4 to 8 digits, or "" for none. Left out, it is not touched. */
  hsn?: string;
}): Promise<StockResult> {
  const supabase = await createClient();
  const { data: savedId, error } = await supabase.rpc("save_ingredient", {
    p_id: input.id as string,
    p_name: input.name,
    p_unit: input.unit,
    p_cost: input.cost,
    p_reorder: input.reorder,
    p_category: (input.category ?? "").trim().slice(0, 40),
    p_purchase_unit: (input.purchaseUnit ?? "").trim().slice(0, 20),
    p_purchase_factor: input.purchaseUnit?.trim() ? input.purchaseFactor || 1 : 1,
    p_item_type: input.itemType,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  if (input.hsn !== undefined && savedId) {
    const { error: hsnError } = await supabase.rpc("set_ingredient_hsn", { p_id: savedId as string, p_hsn: input.hsn });
    if (hsnError) {
      revalidatePath("/stock");
      return { ok: false, error: `The item was saved, but not its HSN code: ${friendlyDbError(hsnError)}` };
    }
  }
  revalidatePath("/stock");
  return { ok: true, message: input.id ? "Item saved." : `${input.name} added.` };
}

export async function saveRecipe(productId: string, lines: { ingredient_id: string; qty: number }[]): Promise<StockResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_recipe", { p_product_id: productId, p_lines: lines as unknown as Json });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock");
  return { ok: true, message: "Recipe saved. Sales now use up these ingredients." };
}

/** One tap = one entry: the screen makes a reference when the form opens and sends the same one on a retry or double click. */
function ref(clientRef: string | undefined): string {
  return clientRef && /^[0-9a-f-]{36}$/i.test(clientRef) ? clientRef : crypto.randomUUID();
}

/** Quick stock-in: several ingredients bought, one receipt. Weighted-average cost is updated by the database. */
export async function stockInQuick(input: { lines: StockInLine[]; supplierNote: string; billRef: string; clientRef?: string }): Promise<StockResult> {
  if (input.lines.length === 0) return { ok: false, error: "Add at least one ingredient." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("stock_in_quick", {
    p_lines: input.lines as unknown as Json,
    p_supplier_note: input.supplierNote.trim().slice(0, 120),
    p_bill_ref: input.billRef.trim().slice(0, 60),
    p_client_ref: ref(input.clientRef),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock");
  // stock_in_quick answers {lines: [...], count, total_value}
  const r = (data ?? {}) as { count?: number; total_value?: number };
  return { ok: true, message: `Stock in saved${r.count ? ` (${r.count} item${r.count === 1 ? "" : "s"})` : ""}.` };
}

/** Wastage, or adding / taking off stock by hand. A reason is required. */
export async function adjustStock(input: { ingredientId: string; kind: AdjustKind; qty: number; reason: string; note: string; clientRef?: string }): Promise<StockResult> {
  if (!(input.qty > 0)) return { ok: false, error: "Enter a quantity above zero." };
  if (!input.reason) return { ok: false, error: "Choose a reason." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjust_stock", {
    p_ingredient: input.ingredientId,
    p_kind: input.kind,
    p_qty: input.qty,
    p_reason: input.reason,
    p_note: input.note.trim().slice(0, 200),
    p_client_ref: ref(input.clientRef),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock");
  // adjust_stock answers {movement_id, kind, change, value, stock}
  const r = (data ?? {}) as { stock?: number };
  const left = r.stock;
  return { ok: true, message: left == null ? "Saved." : `Saved. Stock now ${fmtQty(left)}.` };
}

/** Saves a whole stock count. The database reads the expected quantities at the moment of saving. */
export async function applyStockCount(input: { lines: CountLine[]; note: string; clientRef?: string; openedAt?: string }): Promise<StockResult> {
  if (input.lines.length === 0) return { ok: false, error: "Enter at least one counted quantity." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("stock_count_apply", {
    p_lines: input.lines as unknown as Json,
    p_note: input.note.trim().slice(0, 200),
    p_client_ref: ref(input.clientRef),
    // Expected stock is taken as it was when the sheet was opened, so sales made while counting do not show as differences.
    p_counted_at: input.openedAt && !Number.isNaN(Date.parse(input.openedAt)) ? input.openedAt : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock");
  revalidatePath("/stock/count");
  // stock_count_apply answers {count_id, lines, adjusted, variance_value}
  const r = (data ?? {}) as { adjusted?: number; variance_value?: number };
  const parts = [r.adjusted == null ? null : `${r.adjusted} item${r.adjusted === 1 ? "" : "s"} corrected`, r.variance_value == null ? null : `difference in value ${fmtQty(r.variance_value)}`].filter(Boolean);
  return { ok: true, message: parts.length ? `Count saved (${parts.join(", ")}).` : "Count saved." };
}
