"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type ActionResult = { ok: true; message?: string } | { ok: false; error: string };

/**
 * Money actions on an existing bill. None of them change amounts here — each
 * calls a database function that checks the caller's permission, locks the
 * bill, applies the change and writes the audit log in one transaction.
 */

export async function payBill(input: {
  orderId: string;
  paymentMethodId: string;
  tendered: number | null;
}): Promise<ActionResult> {
  if (!input.paymentMethodId) return { ok: false, error: "Choose how the customer paid." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pay_order", {
    p_order_id: input.orderId,
    p_payment_method_id: input.paymentMethodId,
    p_tendered: input.tendered ?? undefined,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/bills/${input.orderId}`);
  revalidatePath("/bills");
  const change = Number((data as { change?: number } | null)?.change ?? 0);
  return { ok: true, message: change > 0 ? `Paid. Give back change of ${change.toFixed(2)}.` : "Paid." };
}

export async function voidBill(input: { orderId: string; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the void." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("void_order", { p_order_id: input.orderId, p_reason: reason });
  if (error) return { ok: false, error: error.message };
  revalidatePath(`/bills/${input.orderId}`);
  revalidatePath("/bills");
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
