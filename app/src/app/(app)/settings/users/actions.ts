"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type StaffResult =
  | { ok: true; message?: string; code?: string; name?: string; email?: string }
  | { ok: false; error: string };

/**
 * Staff changes all go through database functions that check `user.manage`,
 * stop anyone but an owner from creating or changing an owner, stop you from
 * changing your own access, and write the audit log. Invite codes are stored
 * only as a hash; the plain code is shown once, here, and never again.
 */

export async function inviteStaff(input: { name: string; email: string; roleId: string; phone: string }): Promise<StaffResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("invite_staff", {
    p_full_name: input.name.trim(),
    p_email: input.email.trim(),
    p_role_id: input.roleId,
    p_phone: input.phone.trim() || undefined,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  const d = data as unknown as { invite_code: string };
  return { ok: true, code: d.invite_code, name: input.name.trim(), email: input.email.trim().toLowerCase() };
}

export async function newInviteCode(userId: string, name: string, email: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("regenerate_invite", { p_user_id: userId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  return { ok: true, code: (data as unknown as { invite_code: string }).invite_code, name, email };
}

export async function cancelInvite(userId: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_invite", { p_user_id: userId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  return { ok: true, message: "Invitation cancelled." };
}

export async function changeRole(userId: string, roleId: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_staff", { p_user_id: userId, p_role_id: roleId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  return { ok: true, message: "Role changed. It applies the next time they open a screen." };
}

export async function setActive(userId: string, active: boolean): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_staff", { p_user_id: userId, p_is_active: active });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  return { ok: true, message: active ? "Access switched back on." : "Access switched off. They can no longer sign in to this restaurant." };
}
