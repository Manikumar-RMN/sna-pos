"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
type R<T = object> = ({ ok: true } & T) | { ok: false; error: string };
const clean = (m: string) => m.replace(/^.*?ERROR:\s*/i, "").trim();

/**
 * Tells the online-ordering partner what happened (accepted, rejected, ready), when the channel has a partner address.
 * The database builds and signs the message; it is sent from here. Returns a short note for the screen.
 */
async function tellPartner(id: string, event: "accepted" | "rejected" | "ready"): Promise<string | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("online_order_callback", { p_id: id, p_event: event });
  if (error || !data) return null;
  const cb = data as { url: string; body: string; signature: string };
  try {
    const res = await fetch(cb.url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-SNA-Signature": cb.signature, "User-Agent": "SNA-POS/1" },
      body: cb.body,
      signal: AbortSignal.timeout(6000),
      redirect: "error",
      cache: "no-store",
    });
    return res.ok ? "Partner told." : `The partner did not accept the update (${res.status}). Tell them by phone if needed.`;
  } catch {
    return "Could not reach the partner. Tell them by phone if needed.";
  }
}

export async function acceptOnline(id: string): Promise<R<{ bill: string; partner: string | null }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("online_order_accept", { p_id: id });
  if (error) return { ok: false, error: clean(friendlyDbError(error)) };
  const partner = await tellPartner(id, "accepted");
  revalidatePath("/online-orders");
  return { ok: true, bill: (data as { bill_number: string }).bill_number, partner };
}

export async function rejectOnline(id: string, reason: string): Promise<R<{ partner: string | null }>> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("online_order_reject", { p_id: id, p_reason: reason });
  if (error) return { ok: false, error: clean(friendlyDbError(error)) };
  const partner = await tellPartner(id, "rejected");
  revalidatePath("/online-orders");
  return { ok: true, partner };
}

export async function markOnlineReady(id: string): Promise<R<{ partner: string | null }>> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("online_order_mark_ready", { p_id: id });
  if (error) return { ok: false, error: clean(friendlyDbError(error)) };
  const partner = await tellPartner(id, "ready");
  revalidatePath("/online-orders");
  return { ok: true, partner };
}

export type Channel = { channel: string; url: string | null; updated_at: string };

/** Saves a channel's partner address. Returns the shared secret only when it is new. */
export async function saveChannel(channel: string, url: string, newSecret: boolean): Promise<R<{ secret: string | null }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("online_channel_save", { p_channel: channel, p_url: url, p_new_secret: newSecret });
  if (error) return { ok: false, error: clean(friendlyDbError(error)) };
  revalidatePath("/online-orders");
  return { ok: true, secret: (data as { secret: string | null }).secret };
}
