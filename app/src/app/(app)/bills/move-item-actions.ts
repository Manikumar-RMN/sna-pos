"use server";

import { revalidatePath } from "next/cache";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";
import { createClient } from "@/lib/supabase/server";

export type MoveItemsResult =
  | { ok: true; message: string; toOrderId: string; toBillNumber: string; toTable: string; newBill: boolean; repeat: boolean }
  | { ok: false; error: string };

/**
 * Moves items (whole lines or part of a line) from a running bill to another table (public.move_order_items, migration 132).
 * No amount is worked out here: the database keeps each line's price and tax, recalculates both bills, refuses a paid / discounted /
 * voided bill, repoints the kitchen tickets and writes the audit row, all in one transaction. The same `clientRef` on a retry
 * gives the same answer and never moves twice.
 */
export async function moveItems(input: {
  orderId: string;
  toTableId: string;
  items: { order_item_id: string; qty: number }[];
  clientRef?: string;
}): Promise<MoveItemsResult> {
  const items = input.items.filter((i) => i.qty > 0);
  if (items.length === 0) return { ok: false, error: "Choose the items to move." };
  if (!input.toTableId) return { ok: false, error: "Choose the table to move them to." };
  const supabase = await createClient();
  // Called through a loose type: database.types.ts gets the entry when it is regenerated (see docs/handover/WS-B).
  const loose = supabase as unknown as {
    rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message?: string; code?: string } | null }>;
  };
  const { data, error } = await loose.rpc("move_order_items", {
    p_order_id: input.orderId,
    p_items: items as unknown as Json,
    p_to_table: input.toTableId,
    p_client_ref: input.clientRef && /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : null,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  const res = (data ?? {}) as { to_order_id?: string; to_bill_number?: string; to_table?: string; new_bill?: boolean; repeat?: boolean };
  const toOrderId = res.to_order_id ?? "";
  revalidatePath(`/bills/${input.orderId}`);
  if (toOrderId) revalidatePath(`/bills/${toOrderId}`);
  revalidatePath("/bills");
  revalidatePath("/pos");
  revalidatePath("/captain");
  revalidatePath("/kitchen");
  revalidatePath("/dashboard");
  const table = res.to_table ?? "";
  return {
    ok: true,
    toOrderId,
    toBillNumber: res.to_bill_number ?? "",
    toTable: table,
    newBill: !!res.new_bill,
    repeat: !!res.repeat,
    message: res.repeat
      ? "These items were already moved."
      : res.new_bill
        ? `Moved to a new bill ${res.to_bill_number ?? ""} on table ${table}.`
        : `Moved to bill ${res.to_bill_number ?? ""} on table ${table}.`,
  };
}
