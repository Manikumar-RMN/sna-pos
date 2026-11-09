"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

export async function saveAccount(id: string | null, name: string, phone: string, limit: number | null, company: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("account_save", {
    p_customer: (id ?? null) as string,
    p_name: name,
    p_phone: phone,
    p_limit: (limit ?? null) as number,
    p_company: company || undefined,
  });
  if (error) return { error: clean(friendlyDbError(error)) };
  revalidatePath("/accounts");
  return { error: null };
}

export async function settleAccount(id: string, methodId: string, amount: number, note: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("account_settle", { p_customer: id, p_method: methodId, p_amount: amount, p_note: note || undefined });
  if (error) return { error: clean(friendlyDbError(error)) };
  revalidatePath("/accounts");
  revalidatePath("/shift");
  return { error: null };
}

export async function chargeToAccount(orderId: string, customerId: string): Promise<{ error: string | null }> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("account_charge", { p_order: orderId, p_customer: customerId });
  if (error) return { error: clean(friendlyDbError(error)) };
  revalidatePath(`/bills/${orderId}`);
  revalidatePath("/bills");
  revalidatePath("/accounts");
  return { error: null };
}

export async function statement(id: string, from: string, to: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("account_statement", { p_customer: id, p_from: from, p_to: to });
  if (error) return { ok: false as const, error: clean(friendlyDbError(error)) };
  return { ok: true as const, data: data as unknown as Statement };
}

export type Statement = {
  customer: { name: string; phone: string | null; company: string | null; limit: number | null };
  from: string;
  to: string;
  opening: number;
  closing: number;
  entries: { at: string; kind: string; amount: number; note: string | null; bill: string | null; order_id: string | null; method: string | null; balance: number }[];
};
