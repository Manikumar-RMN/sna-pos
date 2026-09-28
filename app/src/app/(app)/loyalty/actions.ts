"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export async function sellGiftCard(value: number, methodId: string, phone: string, name: string, validDays: number) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_gift_card", {
    p_value: value,
    p_method_id: methodId,
    p_phone: phone || undefined,
    p_name: name || undefined,
    p_valid_days: validDays,
  });
  if (error) return { ok: false as const, error: error.message };
  revalidatePath("/loyalty");
  const d = data as { code: string; value: number; expires_on: string | null };
  return { ok: true as const, code: d.code, value: Number(d.value), expires: d.expires_on };
}

export async function checkGiftCard(code: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("gift_card_lookup", { p_code: code });
  if (error) return { ok: false as const, error: error.message };
  const d = data as { code: string; balance: number; value: number; expires_on: string | null; expired: boolean };
  return { ok: true as const, ...d };
}

export async function saveLoyaltyRules(spendPerPoint: number, pointValue: number, minRedeem: number) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_loyalty_settings", {
    p_spend_per_point: spendPerPoint,
    p_point_value: pointValue,
    p_min_redeem: minRedeem,
  });
  if (error) return { ok: false as const, error: error.message };
  revalidatePath("/loyalty");
  return { ok: true as const, message: "Loyalty rules saved." };
}
