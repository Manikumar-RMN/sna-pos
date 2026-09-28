"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export async function clockIn() {
  const supabase = await createClient();
  const { error } = await supabase.rpc("clock_in");
  if (error) return { ok: false as const, error: error.message };
  revalidatePath("/timesheets");
  return { ok: true as const };
}

export async function clockOut() {
  const supabase = await createClient();
  const { error } = await supabase.rpc("clock_out");
  if (error) return { ok: false as const, error: error.message };
  revalidatePath("/timesheets");
  return { ok: true as const };
}

export async function fixEntry(id: string, clockInIso: string, clockOutIso: string | null, reason: string) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fix_time_entry", { p_id: id, p_in: clockInIso, p_out: clockOutIso as unknown as string, p_reason: reason });
  if (error) return { ok: false as const, error: error.message };
  revalidatePath("/timesheets");
  return { ok: true as const };
}
