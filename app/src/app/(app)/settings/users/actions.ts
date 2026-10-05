"use server";

import { randomInt } from "node:crypto";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type StaffResult =
  | { ok: true; message?: string; code?: string; name?: string; email?: string; pin?: string; tempPassword?: string }
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
  revalidatePath("/welcome");
  const d = data as unknown as { invite_code: string };
  return { ok: true, code: d.invite_code, name: input.name.trim(), email: input.email.trim().toLowerCase() };
}

export async function newInviteCode(userId: string, name: string, email: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("regenerate_invite", { p_user_id: userId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, code: (data as unknown as { invite_code: string }).invite_code, name, email };
}

export async function cancelInvite(userId: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_invite", { p_user_id: userId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, message: "Invitation cancelled." };
}

export async function changeRole(userId: string, roleId: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_staff", { p_user_id: userId, p_role_id: roleId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, message: "Role changed. It applies the next time they open a screen." };
}

export async function setActive(userId: string, active: boolean): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_staff", { p_user_id: userId, p_is_active: active });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, message: active ? "Access switched back on." : "Access switched off. They can no longer sign in to this restaurant." };
}

/**
 * Gives a staff member a new counter PIN, picked at random by the database:
 * unique within the restaurant, 6 digits for owners and managers, 4 for others.
 * It is stored only as a keyed hash, so it is shown once here and can never be
 * read back. People cannot choose their own PIN: if they could, "that PIN is
 * taken" would tell them someone else's PIN.
 */
export async function setPin(userId: string, name: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_staff_pin", { p_user_id: userId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  const pin = (data as { pin?: string } | null)?.pin;
  if (!pin) return { ok: false, error: "The PIN could not be created. Try again." };
  return { ok: true, pin, name };
}

export async function removePin(userId: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("clear_staff_pin", { p_user_id: userId });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, message: "PIN removed. They can no longer unlock a counter tablet." };
}

/** Staff who only ever use the counter tablet: no email, just a name, a role and a PIN. */
export async function addPinStaff(input: { name: string; roleId: string; phone: string }): Promise<StaffResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_pin_staff", {
    p_full_name: input.name.trim(),
    p_role_id: input.roleId,
    p_phone: input.phone.trim() || undefined,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, pin: (data as { pin?: string } | null)?.pin, name: input.name.trim() };
}

/** Easy to read out and type: no 0/O or 1/l/I. */
function temporaryPassword() {
  const letters = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz";
  const digits = "23456789";
  const pick = (set: string, n: number) => Array.from({ length: n }, () => set[randomInt(set.length)]).join("");
  return `${pick(letters, 4)}-${pick(digits, 4)}-${pick(letters, 4)}`;
}

/**
 * A manager sets a temporary password for someone who is locked out. They are
 * signed out everywhere and must choose their own password at the next sign-in.
 */
export async function resetPassword(userId: string, name: string): Promise<StaffResult> {
  const temp = temporaryPassword();
  const supabase = await createClient();
  const { error } = await supabase.rpc("admin_reset_password", { p_user_id: userId, p_new_password: temp });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, tempPassword: temp, name };
}
