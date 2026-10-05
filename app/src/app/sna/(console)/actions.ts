"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type SnaResult = { ok: true; message: string } | { ok: false; error: string };

function done(message: string, path = "/sna"): SnaResult {
  revalidatePath(path, "layout");
  return { ok: true, message };
}

export async function setEdition(restaurantId: string, edition: "basic" | "professional", note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_edition", { p_restaurant: restaurantId, p_edition: edition, p_note: note || undefined });
  if (error) return { ok: false, error: error.message };
  return done(edition === "professional" ? "Upgraded to Professional." : "Moved to Basic.");
}

export async function setModule(restaurantId: string, module: string, on: boolean, note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_module", { p_restaurant: restaurantId, p_module: module, p_on: on, p_note: note || undefined });
  if (error) return { ok: false, error: error.message };
  return done(on ? "Module switched on." : "Module switched off.");
}

export async function decideRequest(id: string, approve: boolean, note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_decide_request", { p_id: id, p_approve: approve, p_note: note || undefined });
  if (error) return { ok: false, error: error.message };
  return done(approve ? "Approved." : "Rejected.");
}

export async function createOutlet(input: {
  requestId: string;
  name: string;
  code: string;
  city: string;
  address: string;
  phone: string;
}): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_create_outlet", {
    p_request: input.requestId,
    p_name: input.name,
    p_code: input.code,
    p_city: input.city,
    p_address: input.address || undefined,
    p_phone: input.phone || undefined,
  });
  if (error) return { ok: false, error: error.message };
  return done("Outlet added. The owner can now see it.");
}

export async function addOutletRequest(restaurantId: string, name: string, city: string, note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_add_request", {
    p_restaurant: restaurantId,
    p_kind: "outlet",
    p_outlet_name: name,
    p_outlet_city: city || undefined,
    p_note: note || undefined,
  });
  if (error) return { ok: false, error: error.message };
  return done("Outlet request added. Sales approves it, then an implementer adds it.");
}

export async function saveStaff(email: string, fullName: string, role: string, active: boolean): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_save_staff", { p_email: email, p_full_name: fullName, p_role: role, p_active: active });
  if (error) return { ok: false, error: error.message };
  return done("Saved.");
}

export async function setPrice(item: string, currency: string, price: string): Promise<SnaResult> {
  const supabase = await createClient();
  const value = price.trim() === "" ? null : Number(price);
  if (value !== null && !Number.isFinite(value)) return { ok: false, error: "Enter a number." };
  const { error } = await supabase.rpc("sna_set_price", { p_item: item, p_currency: currency, p_price: value as number });
  if (error) return { ok: false, error: error.message };
  return done("Price saved.");
}
