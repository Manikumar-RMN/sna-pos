"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";
import type { Json } from "@/lib/supabase/database.types";

export type Senior = { kind: "senior" | "pwd"; count: number; diners: number; name: string; id_no: string };

export type CartInput = {
  items: { product_id: string; qty: number; note?: string }[];
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

function cartArgs(input: CartInput) {
  return {
    p_items: input.items.map((i) => ({ product_id: i.product_id, qty: i.qty, note: i.note ?? "" })) as unknown as Json,
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
  if (input.discount_amount > 0 && !can(user, "order.discount")) {
    return { ok: false, error: "A manager must approve a discount." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_order", {
    ...cartArgs(input),
    p_order_type: input.order_type,
    p_table_id: input.order_type === "dine_in" ? (input.table_id ?? undefined) : undefined,
    p_payment_method_id: input.payment_method_id ?? undefined,
    p_tendered: input.payment_method_id ? (input.tendered ?? undefined) : undefined,
    p_discount_reason: input.discount_reason ?? undefined,
  });
  if (error) return { ok: false, error: error.message };

  const res = data as unknown as { order_id: string; bill_number: string };
  if (!res?.order_id) return { ok: false, error: "The bill could not be saved. Please try again." };
  revalidatePath("/bills");
  revalidatePath("/kitchen");
  return { ok: true, orderId: res.order_id, billNumber: res.bill_number };
}
