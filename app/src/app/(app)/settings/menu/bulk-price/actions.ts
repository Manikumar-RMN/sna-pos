"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";
import { checkInput, ROUNDINGS, type BulkMode, type BulkScope, type HistoryRow, type Preview } from "./bulk-price-logic";

/**
 * Bulk price change. The database does all the maths and all the checks (menu.price_change, reason, rounding, scope):
 * bulk_price_preview shows what would change without writing, bulk_price_apply makes the same change as one audited
 * batch, bulk_price_undo puts back the prices that are still where the batch left them. Bills that are already open
 * keep the price they were rung at.
 *
 * An error that contains "(menu.price_change)" means the person lacks the right: the screen then asks for a manager PIN
 * (ApprovalPrompt) and calls the same action again.
 */
export type PreviewResult = { ok: true; preview: Preview } | { ok: false; error: string };
export type ApplyResult = { ok: true; batchId: string; lines: number; repeat: boolean } | { ok: false; error: string };
export type UndoResult = { ok: true; restored: number; skipped: number } | { ok: false; error: string };
export type HistoryResult = { ok: true; rows: HistoryRow[] } | { ok: false; error: string };

type Input = { mode: BulkMode; valueText: string; rounding: number; scope: BulkScope | null; includeBranch: boolean };

function check(input: Input): { ok: true; value: number; scope: BulkScope } | { ok: false; error: string } {
  const c = checkInput({ mode: input.mode, valueText: input.valueText, scope: input.scope });
  if (!c.ok) return c;
  if (!(ROUNDINGS as readonly number[]).includes(input.rounding)) return { ok: false, error: "Round to 0.01, 0.5 or 1." };
  return { ok: true, value: c.value, scope: input.scope as BulkScope };
}

export async function previewBulkPrice(input: Input): Promise<PreviewResult> {
  const c = check(input);
  if (!c.ok) return c;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bulk_price_preview", {
    p_mode: input.mode,
    p_value: c.value,
    p_rounding: input.rounding,
    p_scope: c.scope as Json,
    p_include_branch: input.includeBranch,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return { ok: true, preview: data as unknown as Preview };
}

export async function applyBulkPrice(input: Input & { reason: string; clientRef: string; expectLines: number }): Promise<ApplyResult> {
  const c = check(input);
  if (!c.ok) return c;
  if (input.reason.trim().length < 3) return { ok: false, error: "Give a reason for the price change." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bulk_price_apply", {
    p_mode: input.mode,
    p_value: c.value,
    p_rounding: input.rounding,
    p_scope: c.scope as Json,
    p_include_branch: input.includeBranch,
    p_reason: input.reason.trim(),
    p_client_ref: /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : undefined,
    p_expect_lines: input.expectLines,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/menu");
  revalidatePath("/settings/menu/bulk-price");
  revalidatePath("/pos");
  const r = (data ?? {}) as { batch_id?: string; total_lines?: number; already_applied?: boolean };
  return { ok: true, batchId: r.batch_id ?? "", lines: Number(r.total_lines ?? 0), repeat: !!r.already_applied };
}

export async function undoBulkPrice(batchId: string, reason: string): Promise<UndoResult> {
  if (!/^[0-9a-f-]{36}$/i.test(batchId)) return { ok: false, error: "Price change not found." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bulk_price_undo", { p_batch: batchId, p_reason: reason.trim() || undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/menu");
  revalidatePath("/settings/menu/bulk-price");
  revalidatePath("/pos");
  const r = (data ?? {}) as { restored?: number; skipped?: number };
  return { ok: true, restored: Number(r.restored ?? 0), skipped: Number(r.skipped ?? 0) };
}

export async function loadBulkPriceHistory(): Promise<HistoryResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("bulk_price_history", { p_limit: 20 });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return { ok: true, rows: (data ?? []) as unknown as HistoryRow[] };
}
