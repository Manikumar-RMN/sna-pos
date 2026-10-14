"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

/** Marks a tax group as liquor: its dishes are billed only on liquor bills, with their own numbers. */
export async function setLiquorGroup(groupId: string, on: boolean): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("tax_group_set_liquor", { p_group: groupId, p_on: on });
  if (error) return { error: clean(friendlyDbError(error)) };
  revalidatePath("/settings/taxes");
  revalidatePath("/pos");
  return { error: null };
}
