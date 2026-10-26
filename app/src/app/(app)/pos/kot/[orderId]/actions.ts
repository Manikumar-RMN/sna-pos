"use server";

import { createClient } from "@/lib/supabase/server";
import { requireUser } from "@/lib/auth";
import { orderTypeLabel } from "@/lib/format";
import { billFormat, paperWidth } from "@/lib/bill-format";
import type { KotPrintInfo, KotSlip } from "./kot-print";

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

/**
 * What a kitchen ticket needs around its items when it is printed on request (the "Sent KOTs" sheet): the bill, where it is,
 * the token, the time zone and this outlet's ticket layout. Read-only.
 */
export async function loadKotPrintInfo(orderId: string): Promise<{ ok: true; info: KotPrintInfo } | { ok: false; error: string }> {
  if (!/^[0-9a-f-]{36}$/i.test(orderId)) return { ok: false, error: "Bill not found." };
  const user = await requireUser();
  const supabase = await createClient();
  const [{ data: order, error }, { data: settings }] = await Promise.all([
    supabase.from("orders").select("id, bill_number, order_type, dining_table_id, token_no, guest_name").eq("id", orderId).maybeSingle(),
    supabase.from("branch_settings").select("bill_format").eq("branch_id", user.branch_id).maybeSingle(),
  ]);
  if (error) return { ok: false, error: friendlyDbError(error) };
  if (!order) return { ok: false, error: "Bill not found." };
  const { data: table } = order.dining_table_id
    ? await supabase.from("dining_tables").select("table_number").eq("id", order.dining_table_id).maybeSingle()
    : { data: null as { table_number: string } | null };
  const type = orderTypeLabel[order.order_type ?? ""] ?? "";
  const guest = order.order_type === "takeaway" || order.order_type === "delivery" ? (order.guest_name ?? "").trim() : "";
  const where = table?.table_number ? `Table ${table.table_number}` : guest ? `${type} · ${guest}` : type;
  const format = billFormat(settings?.bill_format);
  return {
    ok: true,
    info: { billNumber: order.bill_number, where, token: order.token_no ?? null, timezone: user.timezone, printMm: paperWidth(format).printMm, largePrint: format.kot_text === "large" },
  };
}
