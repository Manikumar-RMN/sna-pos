"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";

export type PrResult = { ok: true; message: string } | { ok: false; error: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function sendRequisition(input: { lines: { ingredient_id: string; qty: number }[]; note: string; clientRef: string }): Promise<PrResult> {
  const lines = (input.lines ?? []).filter((l) => UUID.test(l.ingredient_id) && Number.isFinite(l.qty) && l.qty > 0);
  if (lines.length === 0) return { ok: false, error: "Add at least one ingredient with a quantity." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_requisition", {
    p_lines: lines as unknown as Json,
    p_note: input.note || (undefined as unknown as string),
    p_client_ref: UUID.test(input.clientRef) ? input.clientRef : (undefined as unknown as string),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/requisitions");
  const r = (data ?? {}) as { number?: string };
  return { ok: true, message: `${r.number ?? "Requisition"} sent for approval.` };
}

export async function decideRequisition(id: string, action: "approve" | "reject" | "cancel", reason: string): Promise<PrResult> {
  if (!UUID.test(id)) return { ok: false, error: "Requisition not found." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("decide_requisition", { p_id: id, p_action: action, p_reason: reason || (undefined as unknown as string) });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/requisitions");
  const r = (data ?? {}) as { number?: string };
  return { ok: true, message: `${r.number ?? "Requisition"} ${action === "approve" ? "approved" : action === "reject" ? "turned down" : "withdrawn"}.` };
}

export async function makeOrder(id: string, supplierId: string): Promise<PrResult> {
  if (!UUID.test(id) || !UUID.test(supplierId)) return { ok: false, error: "Choose a supplier." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("requisition_to_order", { p_id: id, p_supplier_id: supplierId, p_place: false });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/requisitions");
  revalidatePath("/purchases");
  const r = (data ?? {}) as { purchase_order?: string };
  return { ok: true, message: `${r.purchase_order ?? "Purchase order"} created as a draft. Open Orders to check it and send it.` };
}

export async function saveApprovalLimit(limit: number | null): Promise<PrResult> {
  if (limit !== null && (!Number.isFinite(limit) || limit <= 0)) return { ok: false, error: "Enter an amount above zero, or leave it empty for no limit." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_purchase_approval_limit", { p_limit: limit as number });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/requisitions");
  return { ok: true, message: limit === null ? "No approval limit: any manager can approve." : "Approval limit saved." };
}
