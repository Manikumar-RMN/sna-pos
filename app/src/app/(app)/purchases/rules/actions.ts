"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type RulesResult = { ok: true; message: string } | { ok: false; error: string };

export async function savePurchaseRules(input: { direct: boolean; rateCheck: string; excess: boolean; needsRequisition: boolean; backdateDays: number; blockExpired?: boolean }): Promise<RulesResult> {
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
  if (input.blockExpired !== undefined) {
    const { error: e2 } = await supabase.rpc("set_block_expired_issue", { p_on: input.blockExpired });
    if (e2) return { ok: false, error: friendlyDbError(e2) };
  }
  revalidatePath("/purchases");
  return { ok: true, message: "Purchase rules saved." };
}

export type ApprovalInput = { levels: { level: number; minAmount: number; approverId: string }[]; blockSelf: boolean };

export async function saveApprovalLevels(input: ApprovalInput): Promise<RulesResult> {
  if (!Array.isArray(input.levels) || input.levels.length > 6) return { ok: false, error: "There can be at most 6 levels." };
  for (const l of input.levels) {
    if (!Number.isInteger(l.level) || l.level < 1 || l.level > 6) return { ok: false, error: "A level must be from 1 to 6." };
    if (!Number.isFinite(l.minAmount) || l.minAmount < 0) return { ok: false, error: `Level ${l.level} needs an amount of zero or more.` };
    if (!l.approverId) return { ok: false, error: `Choose who approves level ${l.level}.` };
  }
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_approval_levels", {
    p_levels: input.levels.map((l) => ({ level: l.level, min_amount: l.minAmount, approver_id: l.approverId })),
    p_block_self: !!input.blockSelf,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  return { ok: true, message: input.levels.length === 0 ? "Approval is switched off: orders need no approval." : "Approval levels saved." };
}
