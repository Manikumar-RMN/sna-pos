"use server";

import { createClient } from "@/lib/supabase/server";

/** A manager types their PIN so the signed-in person can do one action they lack the right for (valid 2 minutes). */
export async function approveWithPin(pin: string, permission: string): Promise<{ ok: true; approver: string } | { ok: false; error: string }> {
  if (!/^\d{4,6}$/.test(pin)) return { ok: false, error: "Enter the 4 or 6 digit PIN." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("approve_with_pin", { p_pin: pin, p_permission: permission });
  if (error) return { ok: false, error: error.message };
  const res = (data ?? {}) as { ok?: boolean; error?: string; approver?: string };
  if (!res.ok) return { ok: false, error: res.error ?? "Not approved." };
  return { ok: true, approver: res.approver ?? "Manager" };
}
