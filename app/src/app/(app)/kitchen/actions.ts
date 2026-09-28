"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export async function setTicketStatus(
  ticketId: string,
  status: "preparing" | "ready" | "served",
): Promise<{ ok: boolean; error?: string }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_kitchen_status", { p_ticket_id: ticketId, p_status: status });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/kitchen");
  return { ok: true };
}

/** This device printed these kitchen tickets (so another printer does not print them again). */
export async function markPrinted(ids: string[]): Promise<{ ok: boolean }> {
  if (!ids.length) return { ok: true };
  const supabase = await createClient();
  const { error } = await supabase.rpc("mark_tickets_printed", { p_ids: ids });
  return { ok: !error };
}
