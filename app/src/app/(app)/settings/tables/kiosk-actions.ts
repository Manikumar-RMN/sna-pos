"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

export async function addKiosk(name: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("kiosk_add", { p_name: name });
  if (error) return { error: clean(error.message) };
  revalidatePath("/settings/tables");
  return { error: null };
}

export async function removeKiosk(id: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("kiosk_remove", { p_id: id });
  if (error) return { error: clean(error.message) };
  revalidatePath("/settings/tables");
  return { error: null };
}
