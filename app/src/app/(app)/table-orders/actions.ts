"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
export async function acceptTableOrder(id: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("accept_qr_order", { p_id: id });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath("/table-orders");
  revalidatePath("/pos");
  const d = data as { order_id: string; bill_number: string };
  return { ok: true as const, orderId: d.order_id, bill: d.bill_number };
}

export async function rejectTableOrder(id: string, reason: string) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("reject_qr_order", { p_id: id, p_reason: reason });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath("/table-orders");
  return { ok: true as const };
}
