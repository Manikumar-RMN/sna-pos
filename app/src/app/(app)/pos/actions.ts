"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";

export type PlaceOrderInput = {
  items: { product_id: string; qty: number; note?: string }[];
  order_type: "dine_in" | "takeaway" | "delivery";
  table_id: string | null;
  /** null = save the bill unpaid (pay later / open tab). */
  payment_method_id: string | null;
  tendered: number | null;
  discount_amount: number;
  discount_reason: string | null;
};

export type PlaceOrderResult =
  | { ok: true; orderId: string; billNumber: string }
  | { ok: false; error: string };

/**
 * Takes a bill.
 *
 * The money is NOT calculated here. This action only checks permission and
 * shape, then hands the cart to the database function `create_order`, which
 * computes every rupee — line totals, discount allocation, each frozen tax
 * component, rounding, change — inside one transaction, using prices read from
 * the database rather than anything the browser sent.
 */
export async function placeOrder(input: PlaceOrderInput): Promise<PlaceOrderResult> {
  const user = await getCurrentUser();
  if (!user) return { ok: false, error: "Not signed in." };
  if (!can(user, "order.create")) {
    return { ok: false, error: "You do not have permission to take orders." };
  }
  if (!input.items?.length) return { ok: false, error: "The bill is empty." };
  if (input.discount_amount > 0 && !can(user, "order.discount")) {
    return { ok: false, error: "A manager must approve a discount." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_order", {
    p_items: input.items.map((i) => ({ product_id: i.product_id, qty: i.qty, note: i.note ?? "" })),
    p_order_type: input.order_type,
    p_table_id: input.order_type === "dine_in" ? (input.table_id ?? undefined) : undefined,
    p_payment_method_id: input.payment_method_id ?? undefined,
    p_tendered: input.payment_method_id ? (input.tendered ?? undefined) : undefined,
    p_discount_amount: input.discount_amount,
    p_discount_reason: input.discount_reason ?? undefined,
  });

  if (error) return { ok: false, error: error.message };

  const res = data as unknown as { order_id: string; bill_number: string };
  if (!res?.order_id) return { ok: false, error: "The bill could not be saved. Please try again." };
  revalidatePath("/bills");
  revalidatePath("/kitchen");
  return { ok: true, orderId: res.order_id, billNumber: res.bill_number };
}
