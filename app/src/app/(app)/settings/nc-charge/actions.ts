"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";
import { friendlyDbError } from "@/lib/db-error";

/** Adds, renames, switches on or off one "charge to" account for no-charge bills. The database checks the name and the right. */
export async function saveNcTarget(input: { id: string | null; name: string; active: boolean }): Promise<{ error: string | null }> {
  const user = await getCurrentUser();
  if (!user || !can(user, "settings.manage")) return { error: "Changing this needs the “Manage settings” permission." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_nc_charge_target", { p_id: input.id as string, p_name: input.name, p_active: input.active });
  if (error) return { error: friendlyDbError(error).replace(/^.*?ERROR:\s*/i, "").trim() };
  revalidatePath("/settings/nc-charge");
  return { error: null };
}
