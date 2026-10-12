"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { can, getCurrentUser } from "@/lib/auth";
import type { Json } from "@/lib/supabase/database.types";

export type Senior = { kind: "senior" | "pwd"; count: number; diners: number; name: string; id_no: string };

export type CartItem = { product_id: string; qty: number; note?: string; options?: string[]; hold?: boolean };

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
  /** Guest name, phone and delivery address taken at the counter (takeaway / delivery). All optional. */
  guest?: { name?: string; phone?: string; address?: string } | null;
  /** Captain app: guests at the table (dine-in). */
  covers?: number | null;
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

export type PlaceOrderResult =
  | { ok: true; orderId: string; billNumber: string; /** Token number for the day, when the outlet uses tokens. */ tokenNo: number | null }
  | { ok: false; error: string };

function itemsJson(items: CartItem[]) {
  return items.map((i) => ({ product_id: i.product_id, qty: i.qty, note: i.note ?? "", options: i.options ?? [], hold: !!i.hold })) as unknown as Json;
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

  // Guest details are sent only when something was typed; the database cleans the phone and checks it.
  const guest = {
    guest_name: input.guest?.name?.trim() ?? "",
    guest_phone: input.guest?.phone?.trim() ?? "",
    address: input.guest?.address?.trim() ?? "",
  };
  const hasGuest = !!(guest.guest_name || guest.guest_phone || guest.address);
  const covers = input.order_type === "dine_in" && input.covers && input.covers >= 1 && input.covers <= 99 ? String(Math.round(input.covers)) : null;

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
    p_extra: hasGuest || covers ? { ...(hasGuest ? guest : {}), ...(covers ? { covers } : {}) } : undefined,
  });
  if (error) return { ok: false, error: error.message };

  const res = data as unknown as { order_id: string; bill_number: string; token_no?: number | null };
  if (!res?.order_id) return { ok: false, error: "The bill could not be saved. Please try again." };
  revalidatePath("/bills");
  revalidatePath("/kitchen");
  return { ok: true, orderId: res.order_id, billNumber: res.bill_number, tokenNo: res.token_no ?? null };
}

/**
 * Adds items to an unpaid or part-paid bill. The database recalculates the whole bill.
 * `clientRef` is one id per attempt: a double tap or network retry adds the items once, not twice.
 */
export async function addToBill(orderId: string, items: CartItem[], clientRef?: string): Promise<{ ok: true } | { ok: false; error: string }> {
  if (!items.length) return { ok: false, error: "Add at least one item." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("add_order_items", {
    p_order_id: orderId,
    p_items: itemsJson(items),
    p_client_ref: clientRef && /^[0-9a-f-]{36}$/i.test(clientRef) ? clientRef : undefined,
  });
  if (error) return { ok: false, error: error.message };
  revalidatePath("/bills");
  revalidatePath(`/bills/${orderId}`);
  revalidatePath("/kitchen");
  revalidatePath("/pos");
  return { ok: true };
}

/** Menu, tax rules and a bill-number series so this device can keep billing without the internet. */
export async function getOfflineSnapshot(deviceKey: string): Promise<{ ok: true; snapshot: unknown } | { ok: false; error: string }> {
  if (!/^[0-9a-f-]{36}$/i.test(deviceKey)) return { ok: false, error: "Bad device key." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("offline_snapshot", { p_device_key: deviceKey });
  if (error) return { ok: false, error: error.message };
  return { ok: true, snapshot: data };
}

export type SyncResult = {
  ok: boolean;
  error?: string;
  /** The server is not ready for offline bills yet (for example no shift is open). */
  waiting?: boolean;
  /** The bill is saved on the server; only its guest details are still to be sent. Try again later. */
  guestPending?: boolean;
  /** The bill is saved, but the server would not take its guest details (or they were given up). */
  guestDropped?: boolean;
};

/**
 * Sends one offline bill. Safe to repeat: the server records each bill once, and answers a repeat with the
 * same bill.
 *
 * Guest details typed on the bill are put on it in a second step, once the bill is on the server. If that
 * step fails for a passing reason the bill stays in this device's queue (`guestPending`), and the next try,
 * which finds the bill already saved, does only the guest details. Nothing is recorded twice.
 */
export async function syncOfflineBill(bill: unknown, opts?: { skipGuest?: boolean }): Promise<SyncResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("sync_offline_bill", { p_bill: bill as Json });
  if (error) return { ok: false, error: error.message };
  const res = (data ?? {}) as { ok?: boolean; reason?: string; order_id?: unknown; repeat?: unknown };
  if (res.ok === false) return { ok: false, waiting: true, error: res.reason };
  revalidatePath("/bills");
  revalidatePath("/shift");

  const b = bill && typeof bill === "object" ? (bill as { guest?: unknown; order_type?: unknown }) : {};
  const part = (k: string, max: number) => {
    const v = b.guest && typeof b.guest === "object" ? (b.guest as Record<string, unknown>)[k] : null;
    return typeof v === "string" ? v.trim().slice(0, max) : "";
  };
  // As online: no guest details on a dine-in bill, an address only on delivery.
  const guest = { name: part("name", 80), phone: part("phone", 20), address: b.order_type === "delivery" ? part("address", 300) : "" };
  const orderId = typeof res.order_id === "string" ? res.order_id : null;
  if (b.order_type === "dine_in" || !orderId || !(guest.name || guest.phone || guest.address)) return { ok: true };
  if (opts?.skipGuest) return { ok: true, guestDropped: true };

  const later: SyncResult = { ok: false, guestPending: true, error: "Waiting to send the guest details of an offline bill…" };
  // The bill was already on the server (an earlier try saved it but its answer was lost). If it has guest
  // details by now, leave them: they may have been corrected on the bill screen since.
  if (res.repeat === true) {
    const { data: now, error: readError } = await supabase.from("orders").select("guest_name, guest_phone").eq("id", orderId).maybeSingle();
    if (readError) return later;
    if (now?.guest_name || now?.guest_phone) return { ok: true };
  }
  const setGuest = (phone: string) => supabase.rpc("set_order_guest", { p_order_id: orderId, p_name: guest.name, p_phone: phone, p_address: guest.address });
  // P0001 is the database function itself saying no (a phone number it does not accept, a voided bill): that
  // will be the same next time. Anything else -- no answer, a timeout, a busy server -- is worth another try.
  const refused = (e: { code?: string } | null) => e?.code === "P0001";
  const first = await setGuest(guest.phone);
  if (!first.error) return { ok: true };
  if (!refused(first.error)) return later;
  // Refused. Keep what can be kept: the name and address without the phone.
  if (guest.phone && (guest.name || guest.address)) {
    const second = await setGuest("");
    if (!second.error) return { ok: true, guestDropped: true };
    if (!refused(second.error)) return later;
  }
  return { ok: true, guestDropped: true };
}
