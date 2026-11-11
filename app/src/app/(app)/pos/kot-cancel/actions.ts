"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

/** Winsar "KOT Cancellation": cancel a whole kitchen ticket. The database checks the right to do it, the reason and the bill state. */
export async function cancelKot(ticketId: string, reason: string): Promise<{ ok: true } | { ok: false; error: string }> {
  if (!/^[0-9a-f-]{36}$/i.test(ticketId)) return { ok: false, error: "Choose a KOT." };
  const why = reason.trim();
  if (why.length < 3) return { ok: false, error: "Write a short reason." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("kot_cancel", { p_ticket_id: ticketId, p_reason: why });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/pos/kot-cancel");
  revalidatePath("/kitchen");
  return { ok: true };
}
