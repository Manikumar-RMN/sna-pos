"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
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
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings", "layout");
  return { ok: true, id: data as string };
}

export async function deleteRole(roleId: string): Promise<RoleResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_role", { p_role_id: roleId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings", "layout");
  return { ok: true };
}

export type CopyRightsResult = { ok: true; added: string[]; removed: string[]; total: number } | { ok: false; error: string };

/**
 * Give a profile the rights of another one: mode "add" keeps what it has and adds the other's rights, "replace" makes
 * it exactly the other's. Owners only; the Owner profile can never be the target. The database writes the audit log.
 */
export async function copyRoleRights(fromRoleId: string, toRoleId: string, mode: "add" | "replace"): Promise<CopyRightsResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("copy_role_rights", { p_from_role: fromRoleId, p_to_role: toRoleId, p_mode: mode });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings", "layout");
  const r = (data ?? {}) as { added?: string[]; removed?: string[]; total?: number };
  return { ok: true, added: r.added ?? [], removed: r.removed ?? [], total: Number(r.total ?? 0) };
}
