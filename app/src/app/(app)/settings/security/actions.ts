"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type RoleResult = { ok: true; id?: string } | { ok: false; error: string };

/** Create (roleId null) or change a security profile and its rights. The database allows owners only. */
export async function saveRole(roleId: string | null, name: string, rights: string[]): Promise<RoleResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_role", {
    // null creates a new profile.
    p_role_id: roleId as string,
    p_name: name,
    p_permissions: rights,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings", "layout");
  return { ok: true, id: data as string };
}

export async function deleteRole(roleId: string): Promise<RoleResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_role", { p_role_id: roleId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings", "layout");
  return { ok: true };
}
