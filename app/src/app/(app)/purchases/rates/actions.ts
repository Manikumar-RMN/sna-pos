"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import { isYmd } from "@/lib/format";

export type RateResult = { ok: true; message: string } | { ok: false; error: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function saveRate(input: { supplierId: string; ingredientId: string; rate: string; from: string; to: string; notes: string }): Promise<RateResult> {
  if (!UUID.test(input.supplierId)) return { ok: false, error: "Choose a supplier." };
  if (!UUID.test(input.ingredientId)) return { ok: false, error: "Choose an ingredient." };
  const rate = Number(input.rate.trim());
  if (input.rate.trim() === "" || !Number.isFinite(rate) || rate < 0) return { ok: false, error: "Enter the agreed rate (zero or more)." };
  if (!isYmd(input.from)) return { ok: false, error: "Choose the date the rate starts." };
  if (input.to && !isYmd(input.to)) return { ok: false, error: "Choose a valid end date." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_supplier_rate", {
    p_supplier: input.supplierId,
    p_ingredient: input.ingredientId,
    p_rate: rate,
    p_from: input.from,
    ...(input.to ? { p_to: input.to } : {}),
    ...(input.notes.trim() ? { p_notes: input.notes.trim() } : {}),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/rates");
  revalidatePath("/purchases");
  return { ok: true, message: "Rate saved." };
}

export async function stopRate(id: string): Promise<RateResult> {
  if (!UUID.test(id)) return { ok: false, error: "Rate not found." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("stop_supplier_rate", { p_id: id });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/rates");
  revalidatePath("/purchases");
  return { ok: true, message: "Rate stopped." };
}
