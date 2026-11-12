"use server";

import { can, getCurrentUser } from "@/lib/auth";
import { friendlyDbError } from "@/lib/db-error";
import { createClient } from "@/lib/supabase/server";
import { buildRoundLines, pickRoundTickets, type RoundLine } from "@/lib/repeat-round";

/**
 * "Repeat last order": what was sent to the kitchen in the newest round of this bill, as plain lines (dish id, option ids,
 * quantity, note). Nothing is written and no price is returned: the screen maps the lines onto the CURRENT menu
 * (lib/repeat-round.ts mapRoundToMenu) and the bill is priced by the database when the new items are sent, as always.
 * Same right as taking an order (order.create). No audit row: it only fills the cart.
 */
export async function loadLastRound(
  orderId: string,
): Promise<{ ok: true; lines: RoundLine[]; at: string | null } | { ok: false; error: string }> {
  const user = await getCurrentUser();
  if (!user || !can(user, "order.create")) return { ok: false, error: "Your role does not allow taking orders." };
  if (!/^[0-9a-f-]{36}$/i.test(orderId)) return { ok: false, error: "Bill not found." };
  const supabase = await createClient();

  const { data: order, error: oe } = await supabase.from("orders").select("id, status, payment_status").eq("id", orderId).maybeSingle();
  if (oe) return { ok: false, error: friendlyDbError(oe) };
  if (!order) return { ok: false, error: "Bill not found." };
  if (order.status === "voided" || !["unpaid", "partial"].includes(order.payment_status)) {
    return { ok: false, error: "This bill is closed, so nothing can be added to it." };
  }

  const { data: tickets, error: te } = await supabase
    .from("kitchen_tickets")
    .select("id, status, created_at")
    .eq("order_id", orderId)
    .order("created_at");
  if (te) return { ok: false, error: friendlyDbError(te) };
  const roundIds = pickRoundTickets(tickets ?? []);
  if (roundIds.length === 0) return { ok: true, lines: [], at: null };

  const { data: items, error: ie } = await supabase
    .from("kitchen_ticket_items")
    .select("order_item_id, quantity, status")
    .in("kitchen_ticket_id", roundIds);
  if (ie) return { ok: false, error: friendlyDbError(ie) };
  const orderItemIds = [...new Set((items ?? []).map((i) => i.order_item_id))];
  if (orderItemIds.length === 0) return { ok: true, lines: [], at: null };

  const [{ data: oi, error: oe2 }, { data: mods, error: me }] = await Promise.all([
    supabase.from("order_items").select("id, product_id, product_name, kitchen_note, cancelled_at").in("id", orderItemIds),
    supabase.from("order_item_modifiers").select("order_item_id, modifier_item_id").in("order_item_id", orderItemIds),
  ]);
  if (oe2) return { ok: false, error: friendlyDbError(oe2) };
  if (me) return { ok: false, error: friendlyDbError(me) };

  const lines = buildRoundLines(
    (items ?? []).map((i) => ({ order_item_id: i.order_item_id, quantity: Number(i.quantity), status: i.status })),
    (oi ?? []).map((o) => ({ id: o.id, product_id: o.product_id, product_name: o.product_name, kitchen_note: o.kitchen_note, cancelled_at: o.cancelled_at })),
    (mods ?? []).map((m) => ({ order_item_id: m.order_item_id, modifier_item_id: m.modifier_item_id })),
  );
  const newest = (tickets ?? []).filter((t) => roundIds.includes(t.id)).map((t) => t.created_at).sort().pop() ?? null;
  return { ok: true, lines, at: newest };
}

/**
 * The "+" on a row of the running bill: one more of that dish with the same options and note, as a plain line (dish id, option ids,
 * note). Like "Repeat last order", nothing is written and no price is returned: the screen maps it onto today's menu and the bill is
 * priced by the database when the new items are sent.
 */
export async function loadOneLine(orderId: string, orderItemId: string): Promise<{ ok: true; line: RoundLine } | { ok: false; error: string }> {
  const user = await getCurrentUser();
  if (!user || !can(user, "order.create")) return { ok: false, error: "Your role does not allow taking orders." };
  if (!/^[0-9a-f-]{36}$/i.test(orderId) || !/^[0-9a-f-]{36}$/i.test(orderItemId)) return { ok: false, error: "Item not found." };
  const supabase = await createClient();
  const [{ data: oi, error: oe }, { data: mods, error: me }] = await Promise.all([
    supabase.from("order_items").select("id, product_id, product_name, kitchen_note, cancelled_at").eq("id", orderItemId).eq("order_id", orderId).maybeSingle(),
    supabase.from("order_item_modifiers").select("order_item_id, modifier_item_id").eq("order_item_id", orderItemId),
  ]);
  if (oe) return { ok: false, error: friendlyDbError(oe) };
  if (me) return { ok: false, error: friendlyDbError(me) };
  if (!oi || oi.cancelled_at) return { ok: false, error: "That item is no longer on the bill." };
  const lines = buildRoundLines(
    [{ order_item_id: oi.id, quantity: 1, status: "sent" }],
    [{ id: oi.id, product_id: oi.product_id, product_name: oi.product_name, kitchen_note: oi.kitchen_note, cancelled_at: oi.cancelled_at }],
    (mods ?? []).map((m) => ({ order_item_id: m.order_item_id, modifier_item_id: m.modifier_item_id })),
  );
  if (lines.length === 0) return { ok: false, error: "That item cannot be repeated." };
  return { ok: true, line: lines[0] };
}
