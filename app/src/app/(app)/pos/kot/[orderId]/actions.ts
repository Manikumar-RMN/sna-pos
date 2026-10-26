"use server";

import { createClient } from "@/lib/supabase/server";
import { requireUser } from "@/lib/auth";
import { orderTypeLabel } from "@/lib/format";
import { billFormat, paperWidth } from "@/lib/bill-format";
import type { KotPrintInfo, KotSlip } from "./kot-print";
import { maxPrep, type PrepProduct } from "./prep";

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
    .select("kitchen_ticket_id, order_item_id, product_name, product_name_local, quantity, note, status")
    .in("kitchen_ticket_id", ids);
  const prep = await prepTimes(supabase, (items ?? []).map((i) => i.order_item_id));
  return {
    ok: true,
    slips: round.map((t) => ({
      id: t.id,
      number: t.ticket_number,
      station: t.station ?? "Kitchen",
      createdAt: t.created_at,
      printed: !!t.printed_at,
      prepMin: maxPrep(
        (items ?? []).filter((i) => i.kitchen_ticket_id === t.id && i.status !== "cancelled").map((i) => prep.productOf.get(i.order_item_id)),
        prep.byId,
      ),
      items: (items ?? [])
        .filter((i) => i.kitchen_ticket_id === t.id)
        .map((i) => ({ name: i.product_name, local: i.product_name_local, qty: Number(i.quantity), note: i.note, cancelled: i.status === "cancelled" })),
    })),
  };
}

/**
 * Preparation times for the products behind some order lines (and their dishes, for sizes). A failed read just means no
 * "~N min" on the slip: the ticket must always print.
 */
async function prepTimes(supabase: Awaited<ReturnType<typeof createClient>>, orderItemIds: string[]) {
  const productOf = new Map<string, string>();
  const byId = new Map<string, PrepProduct>();
  const ids = [...new Set(orderItemIds)];
  if (ids.length === 0) return { productOf, byId };
  const { data: lines } = await supabase.from("order_items").select("id, product_id").in("id", ids);
  for (const l of lines ?? []) if (l.product_id) productOf.set(l.id, l.product_id);
  const productIds = [...new Set(productOf.values())];
  if (productIds.length === 0) return { productOf, byId };
  const { data: prods } = await supabase.from("products").select("id, parent_id, prep_minutes").in("id", productIds);
  for (const p of prods ?? []) byId.set(p.id, { id: p.id, parent_id: p.parent_id, prep_minutes: p.prep_minutes });
  const parentIds = [...new Set((prods ?? []).map((p) => p.parent_id).filter((x): x is string => !!x && !byId.has(x)))];
  if (parentIds.length > 0) {
    const { data: parents } = await supabase.from("products").select("id, parent_id, prep_minutes").in("id", parentIds);
    for (const p of parents ?? []) byId.set(p.id, { id: p.id, parent_id: p.parent_id, prep_minutes: p.prep_minutes });
  }
  return { productOf, byId };
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
