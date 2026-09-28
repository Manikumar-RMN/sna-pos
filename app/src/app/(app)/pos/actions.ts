"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";
import type { Json } from "@/lib/supabase/database.types";

export type Senior = { kind: "senior" | "pwd"; count: number; diners: number; name: string; id_no: string };

export type CartItem = { product_id: string; qty: number; note?: string; options?: string[] };

export type CartInput = {
  items: CartItem[];
  discount_amount: number;
  /** null = the restaurant's default; true/false = the customer's choice on this bill. */
  service_charge: boolean | null;
  senior: Senior | null;
};

export type PlaceOrderInput = CartInput & {
  order_type: "dine_in" | "takeaway" | "delivery";
  table_id: string | null;
  /** null = save the bill unpaid (pay later / open tab). */
  payment_method_id: string | null;
  tendered: number | null;
  discount_reason: string | null;
  /** UPI transaction ID, card last 4… for the settlement report. */
  reference?: string | null;
  /** One id per bill attempt: a double tap or network retry returns the same bill instead of a second one. */
  client_ref?: string;
};

export type Quote = {
  subtotal: number;
  discount: number;
  senior_discount: number;
  tax_exempt_amount: number;
  service_charge: number;
  tax_total: number;
  tax_included: number;
  rounding: number;
  grand_total: number;
  taxes: { name: string; rate: number; amount: number }[];
  lines: { key: number; total: number }[];
  service_charge_available: boolean;
  service_charge_on: boolean;
  service_charge_percent: number;
  service_charge_label: string;
  cash_rounding: string;
};

export type PlaceOrderResult = { ok: true; orderId: string; billNumber: string } | { ok: false; error: string };

function itemsJson(items: CartItem[]) {
  return items.map((i) => ({ product_id: i.product_id, qty: i.qty, note: i.note ?? "", options: i.options ?? [] })) as unknown as Json;
}

function cartArgs(input: CartInput) {
  return {
    p_items: itemsJson(input.items),
    p_discount_amount: input.discount_amount,
    p_service_charge: input.service_charge ?? undefined,
    p_senior: (input.senior ?? undefined) as unknown as Json | undefined,
  };
}

/**
 * The live total on the billing screen. It is computed by the same database
 * engine that saves the bill, so the preview and the printed bill can never
 * differ.
 */
export async function quoteOrder(input: CartInput): Promise<{ ok: true; quote: Quote } | { ok: false; error: string }> {
  if (!input.items.length) return { ok: false, error: "empty" };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("quote_order", cartArgs(input));
  if (error) return { ok: false, error: error.message };
  return { ok: true, quote: data as unknown as Quote };
}

/**
 * Takes a bill. This action only checks permission and shape; every amount is
 * computed inside the database function `create_order`, from prices read from
 * the database rather than anything the browser sent.
 */
export async function placeOrder(input: PlaceOrderInput): Promise<PlaceOrderResult> {
  const user = await getCurrentUser();
  if (!user) return { ok: false, error: "Not signed in." };
  if (!can(user, "order.create")) return { ok: false, error: "You do not have permission to take orders." };
  if (!input.items?.length) return { ok: false, error: "The bill is empty." };
  // Discounts: the database checks the right, or a manager's PIN approval.

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_order", {
    ...cartArgs(input),
    p_order_type: input.order_type,
    p_table_id: input.order_type === "dine_in" ? (input.table_id ?? undefined) : undefined,
    p_payment_method_id: input.payment_method_id ?? undefined,
    p_tendered: input.payment_method_id ? (input.tendered ?? undefined) : undefined,
    p_discount_reason: input.discount_reason ?? undefined,
    p_reference: input.payment_method_id && input.reference?.trim() ? input.reference.trim().slice(0, 60) : undefined,
    p_client_ref: input.client_ref && /^[0-9a-f-]{36}$/i.test(input.client_ref) ? input.client_ref : undefined,
  });
  if (error) return { ok: false, error: error.message };

  const res = data as unknown as { order_id: string; bill_number: string };
  if (!res?.order_id) return { ok: false, error: "The bill could not be saved. Please try again." };
  revalidatePath("/bills");
  revalidatePath("/kitchen");
  return { ok: true, orderId: res.order_id, billNumber: res.bill_number };
}

/** Adds items to an unpaid or part-paid bill. The database recalculates the whole bill. */
export async function addToBill(orderId: string, items: CartItem[]): Promise<{ ok: true } | { ok: false; error: string }> {
  if (!items.length) return { ok: false, error: "Add at least one item." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("add_order_items", { p_order_id: orderId, p_items: itemsJson(items) });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/bills");
  revalidatePath(`/bills/${orderId}`);
  revalidatePath("/kitchen");
  revalidatePath("/pos");
  return { ok: true };
}
