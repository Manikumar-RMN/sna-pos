"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import type { Json } from "@/lib/supabase/database.types";

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
  });
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  const res = (data ?? {}) as { change?: number; balance?: number; paid?: boolean; repeat?: boolean };
  if (res.repeat) return { ok: true, message: "This payment was already recorded." };
  const change = Number(res.change ?? 0);
  const changeText = change > 0 ? ` Give back change of ${change.toFixed(2)}.` : "";
  if (res.paid === false) return { ok: true, message: `Part payment taken. ${Number(res.balance ?? 0).toFixed(2)} still to pay.${changeText}` };
  return { ok: true, message: `Paid in full.${changeText}` };
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
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  const res = (data ?? {}) as { changed?: boolean; grand_total?: number };
  if (res.changed === false) return { ok: true, message: "Nothing changed." };
  return { ok: true, message: `Bill updated. New total ${Number(res.grand_total ?? 0).toFixed(2)}.` };
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
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  const res = (data ?? {}) as { from?: string; to?: string };
  return { ok: true, message: `Payment changed from ${res.from ?? "—"} to ${res.to ?? "—"}.` };
}

/** Money back on a paid bill: a credit note dated today, with its own number. */
export async function issueCreditNote(input: { orderId: string; amount: number; methodId: string; reason: string }): Promise<ActionResult> {
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
  });
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  revalidatePath("/shift");
  const res = (data ?? {}) as { number?: string; amount?: number };
  return { ok: true, message: `Credit note ${res.number ?? ""} made for ${Number(res.amount ?? 0).toFixed(2)}.` };
}

/** B2B bill: the customer's GSTIN / tax number and business name, printed on the bill. */
export async function setBillCustomer(input: { orderId: string; taxId: string; name: string }): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_bill_customer", {
    p_order_id: input.orderId,
    p_gstin: input.taxId.trim(),
    p_name: input.name.trim(),
  });
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  return { ok: true, message: input.taxId.trim() ? "Customer tax details added to the bill." : "Customer tax details removed." };
}

/** Sends items held for a later course to the kitchen. */
export async function fireHeld(orderId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fire_held_items", { p_order_id: orderId });
  if (error) return { ok: false, error: error.message };
  refresh(orderId);
  return { ok: true, message: `${(data as { sent?: number } | null)?.sent ?? 0} held item(s) sent to the kitchen.` };
}

export async function cancelItem(input: { orderId: string; itemId: string; qty: number; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for cancelling the item." };
  if (!(input.qty > 0)) return { ok: false, error: "Enter how many to cancel." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_order_item", { p_order_item_id: input.itemId, p_qty: input.qty, p_reason: reason });
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  return { ok: true, message: "Item cancelled. The bill total has been worked out again." };
}

export async function moveTable(input: { orderId: string; tableId: string }): Promise<ActionResult> {
  if (!input.tableId) return { ok: false, error: "Choose a table." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("move_order_table", { p_order_id: input.orderId, p_table_id: input.tableId });
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  return { ok: true, message: `Moved to table ${(data as { table?: string } | null)?.table ?? ""}.` };
}

export async function mergeBills(input: { targetId: string; sourceId: string }): Promise<ActionResult> {
  if (!input.sourceId) return { ok: false, error: "Choose the bill to merge in." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("merge_orders", { p_target_id: input.targetId, p_source_id: input.sourceId });
  if (error) return { ok: false, error: error.message };
  refresh(input.targetId);
  revalidatePath(`/bills/${input.sourceId}`);
  return { ok: true, message: `Bill ${(data as { merged_from?: string } | null)?.merged_from ?? ""} merged into this bill.` };
}

export async function splitBill(input: {
  orderId: string;
  items: { order_item_id: string; qty: number }[];
}): Promise<{ ok: true; newOrderId: string; message: string } | { ok: false; error: string }> {
  const items = input.items.filter((i) => i.qty > 0);
  if (items.length === 0) return { ok: false, error: "Choose the items to move to the new bill." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("split_order", { p_order_id: input.orderId, p_items: items as unknown as Json });
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  const res = data as { order_id: string; bill_number: string };
  return { ok: true, newOrderId: res.order_id, message: `New bill ${res.bill_number} made.` };
}

export async function voidBill(input: { orderId: string; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the void." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("void_order", { p_order_id: input.orderId, p_reason: reason });
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  return { ok: true, message: "Bill voided." };
}

export async function refundBill(input: {
  orderId: string;
  amount: number;
  reason: string;
}): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the refund." };
  if (!(input.amount > 0)) return { ok: false, error: "Enter the amount to refund." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("refund_order", {
    p_order_id: input.orderId,
    p_amount: input.amount,
    p_reason: reason,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/bills/${input.orderId}`);
  revalidatePath("/bills");
  return { ok: true, message: "Refund recorded." };
}

/** Makes the private e-bill link (once) and returns it with the customer's phone if the bill has one. */
export async function shareBillLink(orderId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("share_bill", { p_order: orderId });
  if (error) return { ok: false as const, error: error.message };
  const d = data as { token: string; phone: string | null };
  const h = await headers();
  const origin = `${h.get("x-forwarded-proto") ?? "https"}://${h.get("host")}`;
  return { ok: true as const, url: `${origin}/r/${d.token}`, phone: d.phone };
}
