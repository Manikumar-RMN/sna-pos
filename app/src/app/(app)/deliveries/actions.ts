"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

type R<T = object> = ({ ok: true } & T) | { ok: false; error: string };
const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

export async function saveRider(id: string | null, name: string, phone: string, active = true): Promise<R> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("rider_save", { p_id: (id ?? null) as string, p_name: name, p_phone: phone || undefined, p_active: active });
  if (error) return { ok: false, error: clean(error.message) };
  revalidatePath("/deliveries");
  return { ok: true };
}

export async function updateDelivery(orderId: string, status: "waiting" | "out" | "delivered" | "returned", riderId?: string): Promise<R> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("delivery_update", { p_order: orderId, p_status: status, p_rider: riderId });
  if (error) return { ok: false, error: clean(error.message) };
  revalidatePath("/deliveries");
  return { ok: true };
}

export async function settleRider(riderId: string): Promise<R<{ bills: number; amount: number }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("rider_settle", { p_rider: riderId });
  if (error) return { ok: false, error: clean(error.message) };
  revalidatePath("/deliveries");
  const d = data as { bills: number; amount: number };
  return { ok: true, bills: d.bills, amount: Number(d.amount) };
}
