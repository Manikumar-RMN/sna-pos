"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
export async function setTicketStatus(
  ticketId: string,
  status: "preparing" | "ready" | "served",
): Promise<{ ok: boolean; error?: string }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_kitchen_status", { p_ticket_id: ticketId, p_status: status });
  if (error) return { ok: false, error: friendlyDbError(error) };
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

/**
 * Claims tickets for printing on this device: marks them printed and returns the ones nobody had
 * printed yet. Null when the claim could not be made (then the caller prints as before).
 */
export async function claimForPrint(ids: string[]): Promise<string[] | null> {
  if (!ids.length) return [];
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("claim_tickets_for_print", { p_ids: ids });
  if (error || !Array.isArray(data)) return null;
  return data as string[];
}

/** The kitchen has seen that a waiter cancelled or changed this ticket. */
export async function markKotSeen(ticketId: string): Promise<{ ok: boolean; error?: string }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("kot_kitchen_seen", { p_ticket_id: ticketId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/kitchen");
  return { ok: true };
}
