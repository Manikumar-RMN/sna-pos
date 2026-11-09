"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type RulesResult = { ok: true; message: string } | { ok: false; error: string };

export async function savePurchaseRules(input: { direct: boolean; rateCheck: string; excess: boolean; needsRequisition: boolean; backdateDays: number }): Promise<RulesResult> {
  if (!["off", "warn", "block"].includes(input.rateCheck)) return { ok: false, error: "Choose off, warn or block for the rate check." };
  if (!Number.isInteger(input.backdateDays) || input.backdateDays < 0 || input.backdateDays > 366) return { ok: false, error: "Back-dating days must be a whole number from 0 to 366." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_purchase_rules", {
    p_direct: input.direct,
    p_rate_check: input.rateCheck,
    p_excess: input.excess,
    p_needs_req: input.needsRequisition,
    p_backdate_days: input.backdateDays,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  return { ok: true, message: "Purchase rules saved." };
}
