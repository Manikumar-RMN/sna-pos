"use server";

import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type LogPrintResult =
  | { ok: true; reprint: boolean; action: string; printNo?: number }
  | { ok: false; error: string; /** An offline bill that has not reached the server yet: wait, do not count it as a failure. */ notSynced?: boolean };

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
 * `clientRef` stands in for `orderId` when the print was made from an offline receipt: it is the offline bill's client_id (orders.client_ref).
 * While that bill is not on the server yet the answer is `{ ok: false, notSynced: true }` and the print waits in the device queue
 * (lib/print-log.ts) until the bill has synced. Browser prints (Ctrl+P) are recorded through the same call with `isReprint` set
 * when the screen already knows an earlier copy; the database still decides, and a role without the right gets the PIN message.
 *
 * `isReprint: true` declares a reprint even when the log has no earlier print (a first copy that was never logged); the
 * database then still demands the right or a PIN and numbers it copy 2 or later.
 */
export async function logPrint(input: { kind: "bill" | "kot"; orderId?: string; clientRef?: string; ticketIds?: string[]; isReprint?: boolean; /** Why a reprint is made (required for a reprint). */ reason?: string; /** A print the app could not hold back (Ctrl+P, offline queue): no reason can be asked, so a standard one is written. */ auto?: boolean }): Promise<LogPrintResult> {
  if (input.kind !== "bill" && input.kind !== "kot") return { ok: false, error: "Nothing to print." };
  const uuid = /^[0-9a-f-]{36}$/i;
  const ids = (input.ticketIds ?? []).filter((id) => /^[0-9a-f-]{36}$/i.test(id));
  const supabase = await createClient();
  let orderId = input.orderId;
  if (!orderId && input.clientRef) {
    if (!uuid.test(input.clientRef)) return { ok: false, error: "Bill not found." };
    const found = await supabase.from("orders").select("id").eq("client_ref", input.clientRef).maybeSingle();
    if (found.error) return { ok: false, error: friendlyDbError(found.error) };
    if (!found.data) return { ok: false, notSynced: true, error: "This offline bill has not reached the server yet." };
    orderId = found.data.id;
  }
  if (!orderId || !uuid.test(orderId)) return { ok: false, error: "Bill not found." };
  const { data, error } = await supabase.rpc("log_print", {
    p_kind: input.kind,
    p_order: orderId,
    p_ticket_ids: ids.length > 0 ? ids : undefined,
    // true when the screen already knows this bill was printed (it can only make the call stricter, never skip the check)
    p_is_reprint: input.isReprint === true ? true : undefined,
    p_reason: (input.reason?.trim() || (input.auto ? "Printed from the browser menu or while offline (no reason asked)" : "")) || undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  const r = (data ?? {}) as { reprint?: boolean; action?: string; print_no?: number };
  return { ok: true, reprint: !!r.reprint, action: r.action ?? "", printNo: r.print_no };
}
