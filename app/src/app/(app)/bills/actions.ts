"use server";

import { revalidatePath } from "next/cache";
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
}): Promise<ActionResult> {
  if (!input.paymentMethodId) return { ok: false, error: "Choose how the customer paid." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pay_order", {
    p_order_id: input.orderId,
    p_payment_method_id: input.paymentMethodId,
    p_tendered: input.tendered ?? undefined,
    p_amount: input.amount ?? undefined,
  });
  if (error) return { ok: false, error: error.message };
  refresh(input.orderId);
  const res = (data ?? {}) as { change?: number; balance?: number; paid?: boolean };
  const change = Number(res.change ?? 0);
  const changeText = change > 0 ? ` Give back change of ${change.toFixed(2)}.` : "";
  if (res.paid === false) return { ok: true, message: `Part payment taken. ${Number(res.balance ?? 0).toFixed(2)} still to pay.${changeText}` };
  return { ok: true, message: `Paid in full.${changeText}` };
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
