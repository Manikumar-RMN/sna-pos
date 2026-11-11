"use server";

import { revalidatePath } from "next/cache";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import type { Json } from "@/lib/supabase/database.types";

import { friendlyDbError } from "@/lib/db-error";
export type ActionResult = { ok: true; message?: string } | { ok: false; error: string };

/**
 * Money actions on an existing bill. None of them change amounts here — each
 * calls a database function that checks the caller's permission, locks the
 * bill, applies the change and writes the audit log in one transaction.
 */

function refresh(orderId: string) {
  revalidatePath(`/bills/${orderId}`);
  revalidatePath("/bills");
  revalidatePath("/pos");
  revalidatePath("/kitchen");
  revalidatePath("/dashboard");
}

/** Full payment (amount null) or a part payment towards the balance. */
export async function payBill(input: {
  orderId: string;
  paymentMethodId: string;
  tendered: number | null;
  amount: number | null;
  reference?: string | null;
  /** Same id on a retry = the same payment, never a second one. */
  clientRef?: string;
  /** Optional tip: a memo recorded next to the payment (migration 133), never part of the bill or the cash drawer. Omit for none. */
  tip?: number;
}): Promise<ActionResult> {
  if (!input.paymentMethodId) return { ok: false, error: "Choose how the customer paid." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pay_order", {
    p_order_id: input.orderId,
    p_payment_method_id: input.paymentMethodId,
    p_tendered: input.tendered ?? undefined,
    p_amount: input.amount ?? undefined,
    p_reference: input.reference?.trim() ? input.reference.trim().slice(0, 60) : undefined,
    p_client_ref: input.clientRef && /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : undefined,
    p_tip: input.tip && input.tip > 0 ? input.tip : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const res = (data ?? {}) as { change?: number; balance?: number; paid?: boolean; repeat?: boolean; tip?: number };
  if (res.repeat) return { ok: true, message: "This payment was already recorded." };
  const change = Number(res.change ?? 0);
  const changeText = change > 0 ? ` Give back change of ${change.toFixed(2)}.` : "";
  const tipNote = Number(res.tip ?? 0) > 0 ? ` Tip ${Number(res.tip).toFixed(2)} recorded.` : "";
  if (res.paid === false) return { ok: true, message: `Part payment taken. ${Number(res.balance ?? 0).toFixed(2)} still to pay.${changeText}${tipNote}` };
  return { ok: true, message: `Paid in full.${changeText}${tipNote}` };
}

/** Discount and / or service charge on an unpaid bill. The database checks the rights and recalculates. */
export async function adjustBill(input: {
  orderId: string;
  discount: number;
  reason: string | null;
  serviceCharge: boolean | null;
}): Promise<ActionResult> {
  if (!(input.discount >= 0)) return { ok: false, error: "Enter a discount of zero or more." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("adjust_order", {
    p_order_id: input.orderId,
    p_discount_amount: Math.round(input.discount * 100) / 100,
    p_discount_reason: input.reason?.trim() || undefined,
    p_service_charge: input.serviceCharge ?? undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const res = (data ?? {}) as { changed?: boolean; grand_total?: number };
  if (res.changed === false) return { ok: true, message: "Nothing changed." };
  return { ok: true, message: `Bill updated. New total ${Number(res.grand_total ?? 0).toFixed(2)}.` };
}

/**
 * Complimentary bill (free for a guest) or staff meal: the whole bill comes off and it closes at 0.00.
 * Needs a manager (or a manager's PIN); the database checks this, records the reason and who approved.
 */
export async function makeComplimentary(input: { orderId: string; kind: "complimentary" | "staff_meal"; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason (for example the guest's name or the staff member's name)." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("make_complimentary", { p_order_id: input.orderId, p_kind: input.kind, p_reason: reason.slice(0, 200) });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: input.kind === "complimentary" ? "Bill made complimentary. It is closed at 0.00." : "Bill made a staff meal. It is closed at 0.00." };
}

/** Wrong payment mode on a paid bill (e.g. cash pressed, customer paid by UPI). Only while the shift is open. */
export async function changePaymentMode(input: { orderId: string; paymentId: string; methodId: string; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the change." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("change_payment_method", {
    p_payment_id: input.paymentId,
    p_method_id: input.methodId,
    p_reason: reason,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const res = (data ?? {}) as { from?: string; to?: string };
  return { ok: true, message: `Payment changed from ${res.from ?? "—"} to ${res.to ?? "—"}.` };
}

/** Money back on a paid bill: a credit note dated today, with its own number. */
export async function issueCreditNote(input: {
  orderId: string;
  amount: number;
  methodId: string;
  reason: string;
  /** Same id on a retry = the same credit note, never a second one. */
  clientRef?: string;
}): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason." };
  if (!(input.amount > 0)) return { ok: false, error: "Enter the amount to give back." };
  if (!input.methodId) return { ok: false, error: "Choose how the money is given back." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("issue_credit_note", {
    p_order_id: input.orderId,
    p_amount: Math.round(input.amount * 100) / 100,
    p_method_id: input.methodId,
    p_reason: reason,
    p_client_ref: input.clientRef && /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  revalidatePath("/shift");
  const res = (data ?? {}) as { number?: string; amount?: number; repeat?: boolean };
  if (res.repeat) return { ok: true, message: `Credit note ${res.number ?? ""} for ${Number(res.amount ?? 0).toFixed(2)} was already made.` };
  return { ok: true, message: `Credit note ${res.number ?? ""} made for ${Number(res.amount ?? 0).toFixed(2)}.` };
}

/** Guest name, phone and (delivery bills) address on a bill. The database cleans the phone and finds or starts the customer record. */
export async function setGuestDetails(input: { orderId: string; name: string; phone: string; address?: string | null }): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_order_guest", {
    p_order_id: input.orderId,
    p_name: input.name.trim(),
    p_phone: input.phone.trim(),
    // Only delivery bills carry an address; for other bills the database leaves it alone.
    p_address: input.address != null ? input.address.trim() : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Guest details saved." };
}

/** B2B bill: the customer's GSTIN / tax number and business name, printed on the bill. */
export async function setBillCustomer(input: { orderId: string; taxId: string; name: string }): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_bill_customer", {
    p_order_id: input.orderId,
    p_gstin: input.taxId.trim(),
    p_name: input.name.trim(),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: input.taxId.trim() ? "Customer tax details added to the bill." : "Customer tax details removed." };
}

/** Sends items held for a later course to the kitchen. */
export async function fireHeld(orderId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fire_held_items", { p_order_id: orderId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(orderId);
  return { ok: true, message: `${(data as { sent?: number } | null)?.sent ?? 0} held item(s) sent to the kitchen.` };
}

export async function cancelItem(input: { orderId: string; itemId: string; qty: number; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for cancelling the item." };
  if (!(input.qty > 0)) return { ok: false, error: "Enter how many to cancel." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("cancel_order_item", { p_order_item_id: input.itemId, p_qty: input.qty, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Item cancelled. The bill total has been worked out again." };
}

export async function moveTable(input: { orderId: string; tableId: string }): Promise<ActionResult> {
  if (!input.tableId) return { ok: false, error: "Choose a table." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("move_order_table", { p_order_id: input.orderId, p_table_id: input.tableId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: `Moved to table ${(data as { table?: string } | null)?.table ?? ""}.` };
}

export async function mergeBills(input: { targetId: string; sourceId: string }): Promise<ActionResult> {
  if (!input.sourceId) return { ok: false, error: "Choose the bill to merge in." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("merge_orders", { p_target_id: input.targetId, p_source_id: input.sourceId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.targetId);
  revalidatePath(`/bills/${input.sourceId}`);
  return { ok: true, message: `Bill ${(data as { merged_from?: string } | null)?.merged_from ?? ""} merged into this bill.` };
}

export async function splitBill(input: {
  orderId: string;
  items: { order_item_id: string; qty: number }[];
  /** Same id on a retry = the same new bill, never a second split. */
  clientRef?: string;
}): Promise<{ ok: true; newOrderId: string; message: string } | { ok: false; error: string }> {
  const items = input.items.filter((i) => i.qty > 0);
  if (items.length === 0) return { ok: false, error: "Choose the items to move to the new bill." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("split_order", {
    p_order_id: input.orderId,
    p_items: items as unknown as Json,
    p_client_ref: input.clientRef && /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const res = data as { order_id: string; bill_number: string };
  return { ok: true, newOrderId: res.order_id, message: `New bill ${res.bill_number} made.` };
}

export async function voidBill(input: { orderId: string; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the void." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("void_order", { p_order_id: input.orderId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Bill voided." };
}

/** Cancel settlement: a paid bill goes back to unpaid so it can be settled again. Manager right; the database checks every rule. */
/** Item discount (percent or amount) on one line of an unpaid bill. Manager right; reason required; value 0 removes it. */
export async function setItemDiscount(input: { orderId: string; itemId: string; kind: "percent" | "amount"; value: number; reason: string }): Promise<ActionResult> {
  if (!(input.value >= 0)) return { ok: false, error: "Enter a discount of zero or more." };
  if (input.value > 0 && input.reason.trim().length < 3) return { ok: false, error: "Write a short reason for the discount." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_item_discount", {
    p_order_id: input.orderId,
    p_item_id: input.itemId,
    p_kind: input.value > 0 ? input.kind : "none",
    p_value: input.value,
    p_reason: input.reason.trim() || "removed",
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: `Item discount saved. New total ${Number((data as { grand_total?: number } | null)?.grand_total ?? 0).toFixed(2)}.` };
}

/** Percent discount on every item of one category on an unpaid bill. */
export async function setCategoryDiscount(input: { orderId: string; categoryId: string; percent: number; reason: string }): Promise<ActionResult> {
  if (!input.categoryId) return { ok: false, error: "Choose a category." };
  if (!(input.percent >= 0 && input.percent <= 100)) return { ok: false, error: "Enter a percentage between 0 and 100." };
  if (input.percent > 0 && input.reason.trim().length < 3) return { ok: false, error: "Write a short reason for the discount." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_category_discount", {
    p_order_id: input.orderId,
    p_category_id: input.categoryId,
    p_percent: input.percent,
    p_reason: input.reason.trim() || "removed",
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: `Category discount saved. New total ${Number((data as { grand_total?: number } | null)?.grand_total ?? 0).toFixed(2)}.` };
}

/** Take tax off a bill (or put it back). Only where the owner allowed it; manager right; reason required; audited. */
export async function setBillNoTax(input: { orderId: string; on: boolean; reason: string }): Promise<ActionResult> {
  if (input.reason.trim().length < 3) return { ok: false, error: "Write a short reason." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_bill_no_tax", { p_order_id: input.orderId, p_on: input.on, p_reason: input.reason.trim() });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: `${input.on ? "Tax taken off" : "Tax put back on"}. New total ${Number((data as { grand_total?: number } | null)?.grand_total ?? 0).toFixed(2)}.` };
}

export async function reopenBill(input: { orderId: string; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for cancelling the settlement." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("reopen_order", { p_order_id: input.orderId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "Settlement cancelled. The bill is open again." };
}

/** Makes the private e-bill link (once) and returns it with the customer's phone if the bill has one. */
export async function shareBillLink(orderId: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("share_bill", { p_order: orderId });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  const d = data as { token: string; phone: string | null };
  const h = await headers();
  const origin = `${h.get("x-forwarded-proto") ?? "https"}://${h.get("host")}`;
  return { ok: true as const, url: `${origin}/r/${d.token}`, phone: d.phone };
}

/** Loyalty: find or add the guest by phone and put them on this bill. */
export async function attachCustomer(orderId: string, phone: string, name: string) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("attach_customer", { p_order: orderId, p_phone: phone, p_name: name });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath(`/bills/${orderId}`);
  const d = data as { name: string; phone: string; points: number };
  return { ok: true as const, name: d.name, phone: d.phone, points: Number(d.points) };
}

export async function redeemPoints(orderId: string, points: number) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("redeem_points", { p_order: orderId, p_points: points });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath(`/bills/${orderId}`);
  const d = data as { points_used: number; amount: number };
  return { ok: true as const, message: `${d.points_used} points used (₹${Number(d.amount).toFixed(2)} off the bill).` };
}

export async function redeemGiftCard(orderId: string, code: string, amount: number | null) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("redeem_gift_card", { p_order: orderId, p_code: code, p_amount: amount ?? undefined });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath(`/bills/${orderId}`);
  const d = data as { card: string; used: number; card_balance: number };
  return { ok: true as const, message: `${d.used} taken from gift card ${d.card}. Left on the card: ${d.card_balance}.` };
}

export type RegularGuest = { id: string; name: string | null; visits: number; lastVisitOn: string | null; points: number };

/** "Regular guest" hint: finds the guest by phone (last 10 digits) without changing anything. Never fails the screen. */
export async function findCustomer(phone: string): Promise<RegularGuest | null> {
  const digits = phone.replace(/\D/g, "");
  if (digits.length < 7) return null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("find_customer", { p_phone: phone.trim() });
  if (error || !data) return null;
  const d = data as { id?: string; name?: string | null; visits?: number | string; last_visit_on?: string | null; points?: number | string };
  if (!d.id) return null;
  return { id: d.id, name: d.name ?? null, visits: Number(d.visits ?? 0), lastVisitOn: d.last_visit_on ?? null, points: Number(d.points ?? 0) };
}

export type GuestFavourites = {
  favourites: { productId: string; name: string; qty: number }[];
  recent: { billNumber: string; on: string | null; total: number }[];
};

/** A guest's 3 favourite dishes and last 5 bills (read only; never fails the screen). */
export async function customerFavourites(customerId: string): Promise<GuestFavourites | null> {
  if (!/^[0-9a-f-]{36}$/i.test(customerId)) return null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("customer_favourites", { p_customer: customerId });
  if (error || !data) return null;
  const d = data as { favourites?: { product_id?: string; name?: string; qty?: number | string }[]; recent?: { bill_number?: string; on?: string | null; total?: number | string }[] };
  return {
    favourites: (d.favourites ?? []).filter((f) => f.product_id && f.name).map((f) => ({ productId: String(f.product_id), name: String(f.name), qty: Number(f.qty ?? 0) })),
    recent: (d.recent ?? []).filter((r) => r.bill_number).map((r) => ({ billNumber: String(r.bill_number), on: r.on ?? null, total: Number(r.total ?? 0) })),
  };
}

/** Use points as a discount before tax. The same client ref on a retry = the same redeem, never two. */
export async function redeemPointsDiscount(input: { orderId: string; points: number; clientRef?: string }): Promise<ActionResult> {
  if (!Number.isInteger(input.points) || input.points <= 0) return { ok: false, error: "Enter a whole number of points." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("redeem_points_discount", {
    p_order: input.orderId,
    p_points: input.points,
    p_client_ref: input.clientRef && /^[0-9a-f-]{36}$/i.test(input.clientRef) ? input.clientRef : undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  const d = (data ?? {}) as { points_used?: number | string; discount?: number | string; grand_total?: number | string; points_left?: number | string };
  return {
    ok: true,
    message: `${Number(d.points_used ?? input.points)} points used: ${Number(d.discount ?? 0).toFixed(2)} off before tax. New total ${Number(d.grand_total ?? 0).toFixed(2)}. ${Number(d.points_left ?? 0)} points left.`,
  };
}

/** Takes the points discount off the bill and gives the points back. */
export async function removePointsDiscount(orderId: string): Promise<ActionResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("remove_points_discount", { p_order: orderId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(orderId);
  return { ok: true, message: "Points taken off the bill and given back to the guest." };
}

/** Winsar "NoCharge KOT to KOT": take the complimentary / staff-meal mark off an unpaid bill so it is charged again. */
export async function undoComplimentary(input: { orderId: string; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for charging this bill again." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("undo_complimentary", { p_order_id: input.orderId, p_reason: reason.slice(0, 200) });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "The no-charge mark is off. The bill is charged again." };
}

/** Winsar "KOT Date Transfer": the bill counts towards another business day (unpaid bills, open days, within seven days). */
export async function kotDateTransfer(input: { orderId: string; date: string; reason: string }): Promise<ActionResult> {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input.date)) return { ok: false, error: "Choose the date." };
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the date change." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("kot_date_transfer", { p_order_id: input.orderId, p_business_date: input.date, p_reason: reason.slice(0, 200) });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: `The bill now counts towards ${input.date}.` };
}

/** Winsar "KOT Table Transfer other outlet": an unpaid bill moves to another outlet, onto a free table there or its counter. */
export async function outletTransfer(input: { orderId: string; branchId: string; tableId: string | null; reason: string }): Promise<ActionResult> {
  const reason = input.reason.trim();
  if (reason.length < 3) return { ok: false, error: "Write a short reason for the outlet change." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("order_outlet_transfer", {
    p_order_id: input.orderId,
    p_branch_id: input.branchId,
    p_table_id: input.tableId,
    p_reason: reason.slice(0, 200),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  refresh(input.orderId);
  return { ok: true, message: "The bill moved to the other outlet." };
}
