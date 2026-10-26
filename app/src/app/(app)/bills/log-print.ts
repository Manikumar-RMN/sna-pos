"use server";

import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type LogPrintResult =
  | { ok: true; reprint: boolean; action: string; printNo?: number }
  | { ok: false; error: string };

/**
 * Called just BEFORE a bill or a kitchen ticket is printed (receipt Print button, "Print KOT again", the KOT sheet).
 * The database counts earlier prints: the first print of a bill is free and logged as bill.print; every later print
 * is a reprint that needs the "Reprint bills and KOTs" right (order.reprint) or a manager PIN, and is logged as
 * bill.reprint / kot.reprint. For a kitchen ticket, call this only for a REPRINT; the normal first print goes through
 * claim_tickets_for_print.
 *
 * When the error text contains "(order.reprint)" the screen shows the manager PIN prompt (ApprovalPrompt) and
 * calls this again after approval; print only when `ok` is true.
 *
 * `isReprint: true` declares a reprint even when the log has no earlier print (a first copy that was never logged); the
 * database then still demands the right or a PIN and numbers it copy 2 or later.
 */
export async function logPrint(input: { kind: "bill" | "kot"; orderId: string; ticketIds?: string[]; isReprint?: boolean }): Promise<LogPrintResult> {
  if (input.kind !== "bill" && input.kind !== "kot") return { ok: false, error: "Nothing to print." };
  if (!/^[0-9a-f-]{36}$/i.test(input.orderId)) return { ok: false, error: "Bill not found." };
  const ids = (input.ticketIds ?? []).filter((id) => /^[0-9a-f-]{36}$/i.test(id));
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("log_print", {
    p_kind: input.kind,
    p_order: input.orderId,
    p_ticket_ids: ids.length > 0 ? ids : undefined,
    // true when the screen already knows this bill was printed (it can only make the call stricter, never skip the check)
    p_is_reprint: input.isReprint === true ? true : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  const r = (data ?? {}) as { reprint?: boolean; action?: string; print_no?: number };
  return { ok: true, reprint: !!r.reprint, action: r.action ?? "", printNo: r.print_no };
}
