"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type TaxMoveResult = { ok: true; total: number; toChange: number; taxGroup: string; applied: boolean } | { ok: false; error: string };

/** Counts (apply = false) or makes (apply = true) the move of a menu group's dishes to another tax group. The database checks the right. */
export async function moveToTaxGroup(input: { categoryId: string | null; taxGroupId: string; apply: boolean; reason: string }): Promise<TaxMoveResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bulk_set_tax_group", {
    p_category: input.categoryId as string,
    p_tax_group: input.taxGroupId,
    p_apply: input.apply,
    p_reason: input.reason,
  });
  if (error) return { ok: false, error: friendlyDbError(error).replace(/^.*?ERROR:\s*/i, "").trim() };
  const r = data as { total: number; to_change: number; tax_group: string; applied: boolean };
  if (input.apply) revalidatePath("/settings/menu");
  return { ok: true, total: Number(r.total), toChange: Number(r.to_change), taxGroup: r.tax_group, applied: !!r.applied };
}
