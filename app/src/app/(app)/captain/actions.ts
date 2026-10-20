"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export type KotItem = { id: string; name: string; qty: number; note: string | null; cancelled: boolean; changeText: string | null; byWeight: boolean };
export type Kot = { id: string; number: string; station: string; status: string; createdAt: string; cancelReason: string | null; items: KotItem[] };
export type ReadyAlert = { ticketId: string; ticket: string; station: string | null; table: string | null; bill: string; items: { name: string; qty: number }[]; readyAt: string };

type Result = { ok: true; message: string } | { ok: false; error: string };

function refresh(orderId?: string) {
  revalidatePath("/captain");
  revalidatePath("/kitchen");
  if (orderId) revalidatePath(`/bills/${orderId}`);
}

/** The kitchen tickets (KOTs) already sent for one bill, for the waiter to change or cancel. */
export async function loadBillKots(orderId: string): Promise<{ ok: true; kots: Kot[] } | { ok: false; error: string }> {
  const supabase = await createClient();
  const { data: tickets, error } = await supabase
    .from("kitchen_tickets")
    .select("id, ticket_number, station, status, created_at, cancel_reason")
    .eq("order_id", orderId)
    .order("created_at");
  if (error) return { ok: false, error: friendlyDbError(error) };
  const ids = (tickets ?? []).map((t) => t.id);
  const { data: items, error: e2 } = ids.length
    ? await supabase
        .from("kitchen_ticket_items")
        .select("id, kitchen_ticket_id, order_item_id, product_name, quantity, note, status, change_text")
        .in("kitchen_ticket_id", ids)
        .order("id")
    : { data: [], error: null };
  if (e2) return { ok: false, error: friendlyDbError(e2) };
  const orderItemIds = [...new Set((items ?? []).map((i) => i.order_item_id))];
  const { data: oi } = orderItemIds.length
    ? await supabase.from("order_items").select("id, unit").in("id", orderItemIds)
    : { data: [] as { id: string; unit: string | null }[] };
  const weighed = new Set((oi ?? []).filter((x) => x.unit === "kg").map((x) => x.id));
  return {
    ok: true,
    kots: (tickets ?? []).map((t) => ({
      id: t.id,
      number: t.ticket_number,
      station: t.station ?? "Kitchen",
      status: t.status,
      createdAt: t.created_at,
      cancelReason: t.cancel_reason,
      items: (items ?? [])
        .filter((i) => i.kitchen_ticket_id === t.id)
        .map((i) => ({
          id: i.id,
          name: i.product_name,
          qty: Number(i.quantity),
          note: i.note,
          cancelled: i.status === "cancelled",
          changeText: i.change_text,
          byWeight: weighed.has(i.order_item_id),
        })),
    })),
  };
}

export async function cancelKot(input: { orderId: string; ticketId: string; reason: string }): Promise<Result> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for cancelling the KOT." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("kot_cancel", { p_ticket_id: input.ticketId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "KOT cancelled. The kitchen has been told." };
}

export async function cancelKotItem(input: { orderId: string; itemId: string; qty: number; reason: string }): Promise<Result> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for cancelling the item." };
  if (!(input.qty > 0)) return { ok: false, error: "Enter how many to cancel." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("kot_cancel_item", { p_ticket_item_id: input.itemId, p_qty: input.qty, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Item cancelled. The kitchen has been told." };
}

/** New quantity and/or note for one KOT item. Fewer needs a reason; more goes to the kitchen as a new KOT. */
export async function modifyKotItem(input: { orderId: string; itemId: string; qty: number | null; note: string | null; reason: string }): Promise<Result> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("kot_modify_item", {
    p_ticket_item_id: input.itemId,
    p_qty: input.qty as unknown as number,
    p_note: input.note as unknown as string,
    p_reason: input.reason.trim() || undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Changed. The kitchen has been told." };
}

/** Food that the kitchen marked Ready for this waiter's tables and the waiter has not acknowledged yet. */
export async function fetchReadyAlerts(): Promise<ReadyAlert[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("waiter_ready_alerts");
  if (error || !Array.isArray(data)) return [];
  return (data as unknown as { ticket_id: string; ticket: string; station: string | null; table: string | null; bill: string; items: { name: string; qty: number }[]; ready_at: string }[]).map((a) => ({
    ticketId: a.ticket_id,
    ticket: a.ticket,
    station: a.station,
    table: a.table,
    bill: a.bill,
    items: (a.items ?? []).map((i) => ({ name: i.name, qty: Number(i.qty) })),
    readyAt: a.ready_at,
  }));
}

export async function ackReadyAlert(ticketId: string): Promise<{ ok: boolean }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("waiter_ready_seen", { p_ticket_id: ticketId });
  return { ok: !error };
}
