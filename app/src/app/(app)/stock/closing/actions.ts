"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";

export type ClResult = { ok: true; message: string } | { ok: false; error: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function saveOpening(lines: { ingredient_id: string; qty: number; unit_cost?: number }[]): Promise<ClResult> {
  const clean = (lines ?? []).filter((l) => UUID.test(l.ingredient_id) && Number.isFinite(l.qty) && l.qty > 0);
  if (clean.length === 0) return { ok: false, error: "Add at least one ingredient with a quantity." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_opening_stock", { p_lines: clean as unknown as Json });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock");
  revalidatePath("/stock/closing");
  const r = (data ?? {}) as { lines?: number };
  return { ok: true, message: `Opening stock saved for ${r.lines ?? clean.length} ingredient${clean.length === 1 ? "" : "s"}.` };
}

export async function closeMonth(month: string): Promise<ClResult> {
  if (!/^\d{4}-\d{2}-01$/.test(month)) return { ok: false, error: "Choose a month." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("close_stock_month", { p_month: month });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock/closing");
  return { ok: true, message: "Month closed. Its closing stock is saved." };
}

export async function reopenMonth(id: string, reason: string): Promise<ClResult> {
  if (!UUID.test(id)) return { ok: false, error: "Month not found." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("reopen_stock_month", { p_id: id, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock/closing");
  return { ok: true, message: "Month re-opened." };
}

export async function closeDay(day: string): Promise<ClResult> {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return { ok: false, error: "Choose a day." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("close_stock_day", { p_day: day });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock/closing");
  return { ok: true, message: "Day closed. Nothing can be posted on it now." };
}

export async function reopenDay(id: string, reason: string): Promise<ClResult> {
  if (!UUID.test(id)) return { ok: false, error: "Day not found." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("reopen_stock_day", { p_id: id, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock/closing");
  return { ok: true, message: "Day re-opened." };
}
