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
