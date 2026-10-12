"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

/** Business type; with apply = true the type's starting settings are put on every outlet. */
export async function saveBusinessType(type: string, apply: boolean): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_business_type", { p_type: type, p_apply: apply });
  if (error) return { error: clean(error.message) };
  revalidatePath("/settings", "layout");
  revalidatePath("/pos");
  return { error: null };
}

/** Which kinds of bill this outlet offers, and the one the billing screen starts on. */
export async function saveOrderTypes(types: string[], start: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_order_types", { p_types: types, p_default: start });
  if (error) return { error: clean(error.message) };
  revalidatePath("/settings/charges");
  revalidatePath("/pos");
  return { error: null };
}
