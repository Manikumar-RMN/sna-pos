"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";

export type ProdResult = { ok: true; message: string } | { ok: false; error: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const ref = (r: string) => (UUID.test(r) ? r : (undefined as unknown as string));

function refresh() {
  revalidatePath("/stock/production");
  revalidatePath("/stock");
}

/** The recipe of a prepared item: how much one batch makes, and what goes into it. */
export async function saveRecipe(input: { outputId: string; yieldQty: number; lines: { ingredient_id: string; qty: number }[]; note: string }): Promise<ProdResult> {
  if (!UUID.test(input.outputId)) return { ok: false, error: "Choose the item that is being made." };
  if (!Number.isFinite(input.yieldQty) || input.yieldQty <= 0) return { ok: false, error: "Enter how much one batch makes." };
  const lines = (input.lines ?? []).filter((l) => UUID.test(l.ingredient_id) && Number.isFinite(l.qty) && l.qty > 0);
  if (lines.length === 0) return { ok: false, error: "Add at least one ingredient with a quantity." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_production_bom", {
    p_output: input.outputId,
    p_yield: input.yieldQty,
    p_lines: lines as unknown as Json,
    p_note: input.note || (undefined as unknown as string),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh();
  const r = (data ?? {}) as { item?: string };
  return { ok: true, message: `Recipe for ${r.item ?? "the item"} saved.` };
}

export async function deleteRecipe(outputId: string): Promise<ProdResult> {
  if (!UUID.test(outputId)) return { ok: false, error: "Recipe not found." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("delete_production_bom", { p_output: outputId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh();
  const r = (data ?? {}) as { item?: string };
  return { ok: true, message: `Recipe for ${r.item ?? "the item"} removed.` };
}

/** Put a batch on the plan for today or a later day. Nothing moves until it is made. */
export async function planBatch(input: { outputId: string; qty: number; forDate: string; note: string; clientRef: string }): Promise<ProdResult> {
  if (!UUID.test(input.outputId)) return { ok: false, error: "Choose the item to make." };
  if (!Number.isFinite(input.qty) || input.qty <= 0) return { ok: false, error: "Enter how much to make." };
  if (input.forDate && !DAY.test(input.forDate)) return { ok: false, error: "Choose a valid date." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("plan_production", {
    p_output: input.outputId,
    p_qty: input.qty,
    p_for: input.forDate || undefined,
    p_note: input.note || (undefined as unknown as string),
    p_client_ref: ref(input.clientRef),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh();
  const r = (data ?? {}) as { number?: string };
  return { ok: true, message: `${r.number ?? "Plan"} is on the plan.` };
}

export async function cancelPlan(runId: string): Promise<ProdResult> {
  if (!UUID.test(runId)) return { ok: false, error: "Plan not found." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("cancel_production_plan", { p_run: runId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh();
  const r = (data ?? {}) as { number?: string };
  return { ok: true, message: `${r.number ?? "Plan"} cancelled.` };
}

/** Make a batch: from a plan (pass its id) or straight away (pass the item). The ingredients go out and the prepared item comes in. */
export async function produce(input: { runId: string | null; outputId: string | null; qty: number | null; date: string; note: string; clientRef: string }): Promise<ProdResult> {
  if (input.date && !DAY.test(input.date)) return { ok: false, error: "Choose a valid date." };
  if (!input.runId && !(input.outputId && UUID.test(input.outputId))) return { ok: false, error: "Choose the item that was made." };
  if (input.qty !== null && (!Number.isFinite(input.qty) || input.qty <= 0)) return { ok: false, error: "Enter how much was made." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("produce_batch", {
    p_run: input.runId && UUID.test(input.runId) ? input.runId : undefined,
    p_output: input.outputId && UUID.test(input.outputId) ? input.outputId : undefined,
    p_qty: input.qty ?? undefined,
    p_date: input.date || undefined,
    p_note: input.note || (undefined as unknown as string),
    p_client_ref: ref(input.clientRef),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh();
  const r = (data ?? {}) as { number?: string; item?: string; qty?: number | string; value?: number | string };
  return { ok: true, message: `${r.number ?? "Batch"}: ${Number(r.qty ?? 0)} of ${r.item ?? "the item"} made. The ingredients are out, worth ${Number(r.value ?? 0).toFixed(2)}.` };
}
