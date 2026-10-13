"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

type R<T = object> = ({ ok: true } & T) | { ok: false; error: string };
const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

export async function acceptOnline(id: string): Promise<R<{ bill: string }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("online_order_accept", { p_id: id });
  if (error) return { ok: false, error: clean(error.message) };
  revalidatePath("/online-orders");
  return { ok: true, bill: (data as { bill_number: string }).bill_number };
}

export async function rejectOnline(id: string, reason: string): Promise<R> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("online_order_reject", { p_id: id, p_reason: reason });
  if (error) return { ok: false, error: clean(error.message) };
  revalidatePath("/online-orders");
  return { ok: true };
}
