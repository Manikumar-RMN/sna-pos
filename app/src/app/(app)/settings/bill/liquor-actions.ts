"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

export async function setLiquorPrefix(prefix: string): Promise<{ ok: true; next: string } | { ok: false; error: string }> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_liquor_prefix", { p_prefix: prefix });
  if (error) return { ok: false, error: clean(friendlyDbError(error)) };
  revalidatePath("/settings/bill");
  return { ok: true, next: (data as { next_number: string }).next_number };
}
