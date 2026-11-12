"use server";

import { randomInt, randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { createClient as createPlainClient } from "@supabase/supabase-js";
import { createClient } from "@/lib/supabase/server";
import type { Database } from "@/lib/supabase/database.types";

import { friendlyDbError } from "@/lib/db-error";
export type StaffResult =
  | { ok: true; message?: string; name?: string; tempPassword?: string; userCode?: string; clientCode?: string }
  | { ok: false; error: string };

/**
 * Staff changes all go through database functions that check `user.manage`,
 * stop anyone but an owner from creating or changing an owner, stop you from
 * changing your own access, and write the audit log.
 */

export async function changeRole(userId: string, roleId: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_staff", { p_user_id: userId, p_role_id: roleId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, message: "Role changed. It applies the next time they open a screen." };
}

export async function setActive(userId: string, active: boolean): Promise<StaffResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_staff", { p_user_id: userId, p_is_active: active });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, message: active ? "Access switched back on." : "Access switched off. They can no longer sign in to this restaurant." };
}

/** Clears a sign-in lock (after too many wrong passwords) so the person can try again straight away. Manager right, audited. */
export async function unlockSignIn(userId: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("unlock_staff_login", { p_user_id: userId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/users");
  const name = (data as { name?: string } | null)?.name ?? "The person";
  return { ok: true, message: `${name} can sign in again now.` };
}

export async function addPasswordStaff(input: {
  name: string;
  roleId: string;
  phone: string;
  department?: string;
  designation?: string;
  employeeNo?: string;
  /** The manager may type the password here. Left empty, the system makes a temporary one. */
  password?: string;
  confirmPassword?: string;
}): Promise<StaffResult> {
  const name = input.name.trim();
  if (name.length < 2) return { ok: false, error: "Enter the staff member's name." };
  if (!input.roleId) return { ok: false, error: "Choose a role." };
  // A password the manager typed has to be repeated, so a typo cannot lock the person out.
  const typed = input.password ?? "";
  const again = input.confirmPassword ?? "";
  const managerSet = typed.length > 0 || again.length > 0;
  if (managerSet) {
    if (typed.length < 8) return { ok: false, error: "The password needs at least 8 characters." };
    if (typed !== again) return { ok: false, error: "The two passwords are not the same. Type the same password in both boxes." };
  }
  const temp = managerSet ? typed : temporaryPassword();
  const plain = createPlainClient<Database>(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data: signUp, error: signUpError } = await plain.auth.signUp({ email: `staff-${randomUUID()}@staff.sna-pos.app`, password: temp });
  if (signUpError || !signUp.user) return { ok: false, error: `The sign-in could not be created. ${signUpError ? friendlyDbError(signUpError) : "Please try again."}` };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_password_staff", {
    p_full_name: name,
    p_role_id: input.roleId,
    p_phone: input.phone.trim(),
    p_auth_user_id: signUp.user.id,
    // When the manager chose the password, the person keeps it instead of being made to change it.
    p_must_change: !managerSet,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  const d = (data ?? {}) as { employee_code?: string; client_code?: string };
  // The extra details (department, designation, employee no) are saved with the same call the Details form uses.
  if (d.employee_code && (input.department || input.designation || input.employeeNo)) {
    const { data: row } = await supabase.from("users").select("id").eq("employee_code", d.employee_code).is("deleted_at", null).maybeSingle();
    if (row?.id) {
      await supabase.rpc("update_staff_details", {
        p_user_id: row.id,
        p_full_name: name,
        p_phone: input.phone.trim(),
        p_department: (input.department ?? "").trim(),
        p_designation: (input.designation ?? "").trim(),
        p_employee_no: (input.employeeNo ?? "").trim(),
        p_relieving_date: null as unknown as string,
      });
    }
  }
  if (managerSet) {
    return {
      ok: true,
      name,
      userCode: d.employee_code,
      clientCode: d.client_code,
      message: `${name} added. They sign in with restaurant code ${d.client_code ?? ""}, username ${d.employee_code ?? ""} and the password you typed.`,
    };
  }
  return { ok: true, name, tempPassword: temp, userCode: d.employee_code, clientCode: d.client_code };
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
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, tempPassword: temp, name };
}

/**
 * Gives a person the same role and the same outlets as another person ("Copy access from..."). People hold one role,
 * so this is the way to set someone up like a colleague. The database stops you copying onto yourself, onto or from
 * an owner, and writes the audit log (user.access_copied).
 */
export async function copyAccess(fromUserId: string, toUserId: string, toName: string): Promise<StaffResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("copy_staff_access", { p_from_user: fromUserId, p_to_user: toUserId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  const r = (data ?? {}) as { role?: string; all_outlets?: boolean; outlets?: string[] };
  const where = r.all_outlets ? "all outlets" : `${r.outlets?.length ?? 0} ${(r.outlets?.length ?? 0) === 1 ? "outlet" : "outlets"}`;
  return { ok: true, message: `${toName} now has the ${r.role ?? "same"} role and works in ${where}. It applies the next time they open a screen.` };
}

/** The User Master form: name, department, designation, employee number, mobile and relieving date. */
export async function updateStaffDetails(input: {
  userId: string;
  name: string;
  phone: string;
  department: string;
  designation: string;
  employeeNo: string;
  relievingDate: string;
}): Promise<StaffResult> {
  if (input.name.trim().length < 2) return { ok: false, error: "Enter the staff member's name." };
  if (input.relievingDate && !/^\d{4}-\d{2}-\d{2}$/.test(input.relievingDate)) return { ok: false, error: "Choose a valid relieving date." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("update_staff_details", {
    p_user_id: input.userId,
    p_full_name: input.name.trim(),
    p_phone: input.phone.trim(),
    p_department: input.department.trim(),
    p_designation: input.designation.trim(),
    p_employee_no: input.employeeNo.trim(),
    p_relieving_date: (input.relievingDate || null) as unknown as string,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/users");
  revalidatePath("/welcome");
  return { ok: true, message: `${input.name.trim()} saved.` };
}
