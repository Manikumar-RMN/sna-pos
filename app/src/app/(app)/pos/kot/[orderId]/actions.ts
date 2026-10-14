"use server";

import { createClient } from "@/lib/supabase/server";
import type { KotSlip } from "./kot-printer";

import { friendlyDbError } from "@/lib/db-error";
/**
 * KOT pressed: makes sure the order's new items have kitchen tickets (also when the outlet's
 * automatic tickets are off), and returns the tickets of this round, the ones made in the
 * last minute before the newest one.
 */
export async function loadKot(orderId: string): Promise<{ ok: true; slips: KotSlip[] } | { ok: false; error: string }> {
  const supabase = await createClient();
  const sent = await supabase.rpc("send_to_kitchen", { p_order: orderId });
  if (sent.error) return { ok: false, error: friendlyDbError(sent.error) };

  const { data: tickets, error } = await supabase
    .from("kitchen_tickets")
    .select("id, ticket_number, station, status, created_at, printed_at")
    .eq("order_id", orderId)
    .neq("status", "cancelled")
    .order("created_at");
  if (error) return { ok: false, error: friendlyDbError(error) };
  const all = tickets ?? [];
  if (all.length === 0) return { ok: true, slips: [] };
  const newest = Math.max(...all.map((t) => Date.parse(t.created_at)));
  const round = all.filter((t) => Date.parse(t.created_at) >= newest - 60_000);

  const ids = round.map((t) => t.id);
  const { data: items } = await supabase
    .from("kitchen_ticket_items")
    .select("kitchen_ticket_id, product_name, product_name_local, quantity, note, status")
    .in("kitchen_ticket_id", ids);
  return {
    ok: true,
    slips: round.map((t) => ({
      id: t.id,
      number: t.ticket_number,
      station: t.station ?? "Kitchen",
      createdAt: t.created_at,
      printed: !!t.printed_at,
      items: (items ?? [])
        .filter((i) => i.kitchen_ticket_id === t.id)
        .map((i) => ({ name: i.product_name, local: i.product_name_local, qty: Number(i.quantity), note: i.note, cancelled: i.status === "cancelled" })),
    })),
  };
}

/** Marks the tickets printed and returns those nobody had printed yet; only those are printed here. */
export async function claimTickets(ids: string[]): Promise<string[]> {
  if (ids.length === 0) return [];
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("claim_tickets_for_print", { p_ids: ids });
  if (error || !Array.isArray(data)) return [];
  return data as string[];
}
