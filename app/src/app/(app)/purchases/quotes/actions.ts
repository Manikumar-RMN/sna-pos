"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";
import { isYmd } from "@/lib/format";
import { isUuid, type Fail } from "../helpers";

export type QuoteResult = { ok: true; message: string; id?: string; orders?: { number: string; total: number; supplier_id: string }[] } | Fail;

export async function createQuoteRequest(input: { lines: { ingredient_id: string; qty: number }[]; supplierIds: string[]; neededBy: string; notes: string }): Promise<QuoteResult> {
  const lines = (input.lines ?? []).filter((l) => isUuid(l.ingredient_id) && Number.isFinite(l.qty) && l.qty > 0);
  if (lines.length === 0) return { ok: false, error: "Choose what you want quotes for, with a quantity." };
  const sups = [...new Set((input.supplierIds ?? []).filter(isUuid))];
  if (sups.length < 2) return { ok: false, error: "Choose at least two suppliers to compare." };
  if (input.neededBy && !isYmd(input.neededBy)) return { ok: false, error: "Choose a valid needed-by date." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_rfq", {
    p_lines: lines as unknown as Json,
    p_suppliers: sups,
    p_needed_by: input.neededBy || undefined,
    p_notes: input.notes || undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/quotes");
  const r = (data ?? {}) as { id?: string; number?: string };
  return { ok: true, id: r.id, message: `${r.number ?? "Request"} created. Type in each supplier's rates as they reply.` };
}

export async function saveQuotes(input: { rfqId: string; supplierId: string; rates: { ingredient_id: string; unit_cost: string }[] }): Promise<QuoteResult> {
  if (!isUuid(input.rfqId) || !isUuid(input.supplierId)) return { ok: false, error: "Quotation request not found." };
  const rates: { ingredient_id: string; unit_cost: number }[] = [];
  for (const r of input.rates ?? []) {
    const t = String(r.unit_cost ?? "").trim();
    if (!t) continue;
    const n = Number(t);
    if (!isUuid(r.ingredient_id) || !Number.isFinite(n) || n < 0) return { ok: false, error: "Rates must be numbers, zero or more." };
    rates.push({ ingredient_id: r.ingredient_id, unit_cost: n });
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_rfq_quotes", { p_rfq: input.rfqId, p_supplier: input.supplierId, p_quotes: rates as unknown as Json });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/quotes");
  const r = (data ?? {}) as { rates?: number };
  return { ok: true, message: r.rates ? `${r.rates} rate${r.rates === 1 ? "" : "s"} saved.` : "Cleared: this supplier has no rates on this request." };
}

export async function awardQuotes(input: { rfqId: string; awards: { ingredient_id: string; supplier_id: string }[]; place: boolean }): Promise<QuoteResult> {
  if (!isUuid(input.rfqId)) return { ok: false, error: "Quotation request not found." };
  const awards = (input.awards ?? []).filter((a) => isUuid(a.ingredient_id) && isUuid(a.supplier_id));
  if (awards.length === 0) return { ok: false, error: "Choose a supplier for at least one item." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("award_rfq", { p_rfq: input.rfqId, p_awards: awards as unknown as Json, p_place: !!input.place });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/quotes");
  revalidatePath("/purchases");
  const r = (data ?? {}) as { orders?: { number?: string; total?: number | string; supplier_id?: string }[] };
  const orders = (r.orders ?? []).map((o) => ({ number: o.number ?? "", total: Number(o.total ?? 0), supplier_id: o.supplier_id ?? "" }));
  return { ok: true, orders, message: `${orders.length} purchase order${orders.length === 1 ? "" : "s"} ${input.place ? "sent" : "saved as drafts"}: ${orders.map((o) => o.number).join(", ")}.` };
}

export async function cancelQuoteRequest(rfqId: string, reason: string): Promise<QuoteResult> {
  if (!isUuid(rfqId)) return { ok: false, error: "Quotation request not found." };
  const why = String(reason ?? "").trim();
  if (why.length < 3) return { ok: false, error: "Write a short reason for cancelling." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_rfq", { p_rfq: rfqId, p_reason: why });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases/quotes");
  return { ok: true, message: "Request cancelled." };
}
