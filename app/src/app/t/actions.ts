"use server";

import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";

export type GuestLine = { product_id: string; qty: number; options: string[]; note: string };

/** Guest sends the order from the table QR. Staff accept it before it reaches the kitchen. */
export async function placeGuestOrder(token: string, lines: GuestLine[], name: string, note: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("qr_place_order", {
    p_token: token,
    p_items: lines as unknown as Json,
    p_guest_name: name,
    p_note: note,
  });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  const d = data as { request_id: string; key: string; estimated_total: number };
  return { ok: true as const, id: d.request_id, key: d.key, total: Number(d.estimated_total) };
}

export async function guestOrderStatus(id: string, key: string) {
  const supabase = await createClient();
  const { data } = await supabase.rpc("qr_order_status", { p_request: id, p_key: key });
  return (data as { status: "pending" | "accepted" | "rejected"; reason: string | null; bill_number?: string | null; token_no?: number | null } | null) ?? null;
}
