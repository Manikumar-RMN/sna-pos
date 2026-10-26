"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import type { Json } from "@/lib/supabase/database.types";

import { friendlyDbError } from "@/lib/db-error";
export type ActionResult = { ok: true; message?: string } | { ok: false; error: string };

/**
 * Money actions on an existing bill. None of them change amounts here — each
 * calls a database function that checks the caller's permission, locks the
 * bill, applies the change and writes the audit log in one transaction.
 */

function refresh(orderId: string) {
  revalidatePath(`/bills/${orderId}`);
  revalidatePath("/bills");
  revalidatePath("/pos");
  revalidatePath("/kitchen");
  revalidatePath("/dashboard");
}

/** Full payment (amount null) or a part payment towards the balance. */
export async function payBill(input: {
  orderId: string;
  paymentMethodId: string;
  tendered: number | null;
  amount: number | null;
  reference?: string | null;
  /** Same id on a retry = the same payment, never a second one. */
  clientRef?: string;
  /** Optional tip: a memo recorded next to the payment (migration 133), never part of the bill or the cash drawer. Omit for none. */
  tip?: number;
}): Promise<ActionResult> {
  if (!input.paymentMethodId) return { ok: false, error: "Choose how the customer paid." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pay_order", {
    p_order_id: input.orderId,
    p_payment_method_id: input.paymentMethodId,
    p_tendered: input.tendered ?? undefined,
    p_amount: input.amount ?? undefined,
    p_reference: input.reference?.trim() ? input.reference.trim().slice(0, 60) : undefined,
    p_client_ref: input.clientRef && /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : undefined,
    p_tip: input.tip && input.tip > 0 ? input.tip : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const res = (data ?? {}) as { change?: number; balance?: number; paid?: boolean; repeat?: boolean; tip?: number };
  if (res.repeat) return { ok: true, message: "This payment was already recorded." };
  const change = Number(res.change ?? 0);
  const changeText = change > 0 ? ` Give back change of ${change.toFixed(2)}.` : "";
  const tipNote = Number(res.tip ?? 0) > 0 ? ` Tip ${Number(res.tip).toFixed(2)} recorded.` : "";
  if (res.paid === false) return { ok: true, message: `Part payment taken. ${Number(res.balance ?? 0).toFixed(2)} still to pay.${changeText}${tipNote}` };
  return { ok: true, message: `Paid in full.${changeText}${tipNote}` };
}

/** Discount and / or service charge on an unpaid bill. The database checks the rights and recalculates. */
export async function adjustBill(input: {
  orderId: string;
  discount: number;
  reason: string | null;
  serviceCharge: boolean | null;
}): Promise<ActionResult> {
  if (!(input.discount >= 0)) return { ok: false, error: "Enter a discount of zero or more." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjust_order", {
    p_order_id: input.orderId,
    p_discount_amount: Math.round(input.discount * 100) / 100,
    p_discount_reason: input.reason?.trim() || undefined,
    p_service_charge: input.serviceCharge ?? undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const res = (data ?? {}) as { changed?: boolean; grand_total?: number };
  if (res.changed === false) return { ok: true, message: "Nothing changed." };
  return { ok: true, message: `Bill updated. New total ${Number(res.grand_total ?? 0).toFixed(2)}.` };
}

/**
 * Complimentary bill (free for a guest) or staff meal: the whole bill comes off and it closes at 0.00.
 * Needs a manager (or a manager's PIN); the database checks this, records the reason and who approved.
 */
export async function makeComplimentary(input: { orderId: string; kind: "complimentary" | "staff_meal"; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason (for example the guest's name or the staff member's name)." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("make_complimentary", { p_order_id: input.orderId, p_kind: input.kind, p_reason: reason.slice(0, 200) });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: input.kind === "complimentary" ? "Bill made complimentary. It is closed at 0.00." : "Bill made a staff meal. It is closed at 0.00." };
}

/** Wrong payment mode on a paid bill (e.g. cash pressed, customer paid by UPI). Only while the shift is open. */
export async function changePaymentMode(input: { orderId: string; paymentId: string; methodId: string; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the change." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("change_payment_method", {
    p_payment_id: input.paymentId,
    p_method_id: input.methodId,
    p_reason: reason,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const res = (data ?? {}) as { from?: string; to?: string };
  return { ok: true, message: `Payment changed from ${res.from ?? "—"} to ${res.to ?? "—"}.` };
}

/** Money back on a paid bill: a credit note dated today, with its own number. */
export async function issueCreditNote(input: {
  orderId: string;
  amount: number;
  methodId: string;
  reason: string;
  /** Same id on a retry = the same credit note, never a second one. */
  clientRef?: string;
}): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason." };
  if (!(input.amount > 0)) return { ok: false, error: "Enter the amount to give back." };
  if (!input.methodId) return { ok: false, error: "Choose how the money is given back." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_credit_note", {
    p_order_id: input.orderId,
    p_amount: Math.round(input.amount * 100) / 100,
    p_method_id: input.methodId,
    p_reason: reason,
    p_client_ref: input.clientRef && /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  revalidatePath("/shift");
  const res = (data ?? {}) as { number?: string; amount?: number; repeat?: boolean };
  if (res.repeat) return { ok: true, message: `Credit note ${res.number ?? ""} for ${Number(res.amount ?? 0).toFixed(2)} was already made.` };
  return { ok: true, message: `Credit note ${res.number ?? ""} made for ${Number(res.amount ?? 0).toFixed(2)}.` };
}

/** Guest name, phone and (delivery bills) address on a bill. The database cleans the phone and finds or starts the customer record. */
export async function setGuestDetails(input: { orderId: string; name: string; phone: string; address?: string | null }): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_order_guest", {
    p_order_id: input.orderId,
    p_name: input.name.trim(),
    p_phone: input.phone.trim(),
    // Only delivery bills carry an address; for other bills the database leaves it alone.
    p_address: input.address != null ? input.address.trim() : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Guest details saved." };
}

/** B2B bill: the customer's GSTIN / tax number and business name, printed on the bill. */
export async function setBillCustomer(input: { orderId: string; taxId: string; name: string }): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_bill_customer", {
    p_order_id: input.orderId,
    p_gstin: input.taxId.trim(),
    p_name: input.name.trim(),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: input.taxId.trim() ? "Customer tax details added to the bill." : "Customer tax details removed." };
}

/** Sends items held for a later course to the kitchen. */
export async function fireHeld(orderId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fire_held_items", { p_order_id: orderId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(orderId);
  return { ok: true, message: `${(data as { sent?: number } | null)?.sent ?? 0} held item(s) sent to the kitchen.` };
}

export async function cancelItem(input: { orderId: string; itemId: string; qty: number; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for cancelling the item." };
  if (!(input.qty > 0)) return { ok: false, error: "Enter how many to cancel." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_order_item", { p_order_item_id: input.itemId, p_qty: input.qty, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Item cancelled. The bill total has been worked out again." };
}

export async function moveTable(input: { orderId: string; tableId: string }): Promise<ActionResult> {
  if (!input.tableId) return { ok: false, error: "Choose a table." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("move_order_table", { p_order_id: input.orderId, p_table_id: input.tableId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: `Moved to table ${(data as { table?: string } | null)?.table ?? ""}.` };
}

export async function mergeBills(input: { targetId: string; sourceId: string }): Promise<ActionResult> {
  if (!input.sourceId) return { ok: false, error: "Choose the bill to merge in." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("merge_orders", { p_target_id: input.targetId, p_source_id: input.sourceId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.targetId);
  revalidatePath(`/bills/${input.sourceId}`);
  return { ok: true, message: `Bill ${(data as { merged_from?: string } | null)?.merged_from ?? ""} merged into this bill.` };
}

export async function splitBill(input: {
  orderId: string;
  items: { order_item_id: string; qty: number }[];
  /** Same id on a retry = the same new bill, never a second split. */
  clientRef?: string;
}): Promise<{ ok: true; newOrderId: string; message: string } | { ok: false; error: string }> {
  const items = input.items.filter((i) => i.qty > 0);
  if (items.length === 0) return { ok: false, error: "Choose the items to move to the new bill." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("split_order", {
    p_order_id: input.orderId,
    p_items: items as unknown as Json,
    p_client_ref: input.clientRef && /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const res = data as { order_id: string; bill_number: string };
  return { ok: true, newOrderId: res.order_id, message: `New bill ${res.bill_number} made.` };
}

export async function voidBill(input: { orderId: string; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the void." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("void_order", { p_order_id: input.orderId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Bill voided." };
}

/** Makes the private e-bill link (once) and returns it with the customer's phone if the bill has one. */
export async function shareBillLink(orderId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("share_bill", { p_order: orderId });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  const d = data as { token: string; phone: string | null };
  const h = await headers();
  const origin = `${h.get("x-forwarded-proto") ?? "https"}://${h.get("host")}`;
  return { ok: true as const, url: `${origin}/r/${d.token}`, phone: d.phone };
}

/** Loyalty: find or add the guest by phone and put them on this bill. */
export async function attachCustomer(orderId: string, phone: string, name: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("attach_customer", { p_order: orderId, p_phone: phone, p_name: name });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath(`/bills/${orderId}`);
  const d = data as { name: string; phone: string; points: number };
  return { ok: true as const, name: d.name, phone: d.phone, points: Number(d.points) };
}

export async function redeemPoints(orderId: string, points: number) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("redeem_points", { p_order: orderId, p_points: points });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath(`/bills/${orderId}`);
  const d = data as { points_used: number; amount: number };
  return { ok: true as const, message: `${d.points_used} points used (₹${Number(d.amount).toFixed(2)} off the bill).` };
}

export async function redeemGiftCard(orderId: string, code: string, amount: number | null) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("redeem_gift_card", { p_order: orderId, p_code: code, p_amount: amount ?? undefined });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath(`/bills/${orderId}`);
  const d = data as { card: string; used: number; card_balance: number };
  return { ok: true as const, message: `${d.used} taken from gift card ${d.card}. Left on the card: ${d.card_balance}.` };
}
