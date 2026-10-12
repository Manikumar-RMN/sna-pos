"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

export async function addBatch(productId: string, qty: number, expiresOn: string, madeOn: string, note: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("batch_add", {
    p_product: productId,
    p_qty: qty,
    p_expires_on: expiresOn,
    p_made_on: madeOn || undefined,
    p_note: note || undefined,
  });
  if (error) return { error: clean(error.message) };
  revalidatePath("/batches");
  revalidatePath("/pos");
  return { error: null };
}

export async function writeOffBatch(id: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("batch_write_off", { p_batch: id });
  if (error) return { error: clean(error.message) };
  revalidatePath("/batches");
  revalidatePath("/pos");
  return { error: null };
}
