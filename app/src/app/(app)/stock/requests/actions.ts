"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";

export type ReqResult = { ok: true; message: string } | { ok: false; error: string };
type Line = { ingredient_id: string; qty: number };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const clean = (lines: Line[]) => (lines ?? []).filter((l) => UUID.test(l.ingredient_id) && Number.isFinite(l.qty) && l.qty > 0);
const ref = (r: string) => (UUID.test(r) ? r : (undefined as unknown as string));

/** Ask the store for stock. Anyone with a stock right can ask. */
export async function sendRequest(input: { department: string; lines: Line[]; note: string; clientRef: string }): Promise<ReqResult> {
  const lines = clean(input.lines);
  if (lines.length === 0) return { ok: false, error: "Add at least one ingredient with a quantity." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_material_request", {
    p_department: input.department,
    p_lines: lines as unknown as Json,
    p_note: input.note || (undefined as unknown as string),
    p_client_ref: ref(input.clientRef),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock/requests");
  const r = (data ?? {}) as { number?: string };
  return { ok: true, message: `${r.number ?? "Request"} sent.` };
}

/** Give out stock: against a request (pass its id) or on its own (pass the department). */
export async function issueStock(input: { requestId: string | null; department: string; lines: Line[]; note: string; clientRef: string; issueDate?: string }): Promise<ReqResult> {
  const lines = clean(input.lines);
  if (lines.length === 0) return { ok: false, error: "Enter how much is being issued." };
  if (input.issueDate && !/^\d{4}-\d{2}-\d{2}$/.test(input.issueDate)) return { ok: false, error: "Choose a valid issue date." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_material", {
    p_request: (input.requestId && UUID.test(input.requestId) ? input.requestId : undefined) as unknown as string,
    p_department: input.department || (undefined as unknown as string),
    p_lines: lines as unknown as Json,
    p_note: input.note || (undefined as unknown as string),
    p_client_ref: ref(input.clientRef),
    p_issue_date: input.issueDate || undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock/requests");
  revalidatePath("/stock");
  const r = (data ?? {}) as { number?: string; value?: number | string };
  return { ok: true, message: `${r.number ?? "Issue"} saved. The stock is out, worth ${Number(r.value ?? 0).toFixed(2)}.` };
}

export async function closeRequest(id: string, action: "reject" | "cancel" | "close", reason: string): Promise<ReqResult> {
  if (!UUID.test(id)) return { ok: false, error: "Request not found." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("close_material_request", { p_id: id, p_action: action, p_reason: reason || (undefined as unknown as string) });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/stock/requests");
  const r = (data ?? {}) as { number?: string };
  return { ok: true, message: `${r.number ?? "Request"} ${action === "reject" ? "turned down" : action === "cancel" ? "withdrawn" : "closed"}.` };
}
