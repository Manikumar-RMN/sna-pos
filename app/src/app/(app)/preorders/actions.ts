"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

type R<T = object> = ({ ok: true } & T) | { ok: false; error: string };
const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

export type PreOrderInput = {
  guest_name: string;
  guest_phone: string;
  due_at: string; // ISO with time zone
  order_type: "takeaway" | "delivery";
  address: string;
  note: string;
  items: { product_id: string; qty: number; options?: string[]; note?: string }[];
};

export async function savePreOrder(input: PreOrderInput): Promise<R<{ id: string; number: number; estimate: number }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pre_order_save", { p: JSON.parse(JSON.stringify(input)) });
  if (error) return { ok: false, error: clean(error.message) };
  const d = data as { id: string; number: number; estimate: number };
  revalidatePath("/preorders");
  return { ok: true, id: d.id, number: d.number, estimate: Number(d.estimate) };
}

export async function takeAdvance(id: string, methodId: string, amount: number, reference: string): Promise<R> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("pre_order_advance", { p_id: id, p_method: methodId, p_amount: amount, p_reference: reference || undefined });
  if (error) return { ok: false, error: clean(error.message) };
  revalidatePath("/preorders");
  revalidatePath("/shift");
  return { ok: true };
}

export async function cancelPreOrder(id: string, reason: string, refundMethodId: string | null): Promise<R<{ refunded: number }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pre_order_cancel", { p_id: id, p_reason: reason, p_refund_method: refundMethodId ?? undefined });
  if (error) return { ok: false, error: clean(error.message) };
  revalidatePath("/preorders");
  revalidatePath("/shift");
  return { ok: true, refunded: Number((data as { refunded: number }).refunded) };
}

export async function billPreOrder(id: string): Promise<R<{ orderId: string; billNumber: string; leftOver: number }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pre_order_bill", { p_id: id });
  if (error) return { ok: false, error: clean(error.message) };
  const d = data as { order_id: string; bill_number: string; advance_left_over: number };
  revalidatePath("/preorders");
  revalidatePath("/bills");
  revalidatePath("/kitchen");
  return { ok: true, orderId: d.order_id, billNumber: d.bill_number, leftOver: Number(d.advance_left_over) };
}
