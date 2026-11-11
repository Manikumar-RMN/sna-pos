"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Json } from "@/lib/supabase/database.types";
import { isYmd } from "@/lib/format";
import { amountCents, isPayMethod, isUuid, lineCents, lineTaxCents, type CleanLine, type Fail } from "./helpers";

export type PurchaseResult = { ok: true; message?: string } | Fail;
/** `repeat` is true when this receipt had already been saved by an earlier tap or retry. */
export type ReceiveResult = { ok: true; number: string; total: number; balance: number; repeat: boolean } | Fail;
export type PayResult = { ok: true; amount: number; balance: number } | Fail;
/** `number` is the receipt the payment was for; `balance` is what is owed on it now. */
export type UndoPayResult = { ok: true; amount: number; balance: number; number: string } | Fail;

export type ReturnGoodsResult = { ok: true; number: string; total: number; owed: number; message: string } | Fail;

/** Send goods from a receipt back to the supplier: the stock goes out and the amount owed goes down. */
export async function returnGoods(input: { receiptId: string; lines: { ingredient_id: string; qty: number }[]; reason: string; clientRef: string }): Promise<ReturnGoodsResult> {
  if (!isUuid(input.receiptId)) return { ok: false, error: "Goods receipt not found." };
  const why = String(input.reason ?? "").trim();
  if (why.length < 3) return { ok: false, error: "Write a short reason for the return." };
  const lines = (input.lines ?? []).filter((l) => isUuid(l.ingredient_id) && Number.isFinite(l.qty) && l.qty > 0);
  if (lines.length === 0) return { ok: false, error: "Enter how much is going back." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("return_goods", {
    p_receipt_id: input.receiptId,
    p_lines: lines as unknown as Json,
    p_reason: why,
    p_client_ref: isUuid(input.clientRef) ? input.clientRef : (undefined as unknown as string),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  revalidatePath("/stock");
  const r = (data ?? {}) as { number?: string; total?: number | string; owed?: number | string };
  const total = Number(r.total ?? 0);
  const owed = Number(r.owed ?? 0);
  return { ok: true, number: r.number ?? "", total, owed, message: `${r.number ?? "Return"} saved. The goods are out of stock and ${owed > 0 ? "the amount owed is lower." : "nothing more is owed on this receipt."}` };
}

export type SupplierInput = {
  name: string;
  contactPerson: string;
  phone: string;
  email: string;
  taxNo: string;
  address: string;
  paymentDays: number;
  notes: string;
  isActive: boolean;
};

export async function saveSupplier(id: string | null, input: SupplierInput): Promise<PurchaseResult> {
  if (id !== null && !isUuid(id)) return { ok: false, error: "Supplier not found." };
  if (!String(input.name ?? "").trim()) return { ok: false, error: "Enter the supplier's name." };
  const days = Math.round(Number(input.paymentDays));
  if (!Number.isFinite(days) || days < 0 || days > 365) return { ok: false, error: "Payment days must be between 0 and 365." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_supplier", {
    p_id: id as string,
    p: {
      name: input.name,
      contact_person: input.contactPerson,
      phone: input.phone,
      email: input.email,
      tax_no: input.taxNo,
      address: input.address,
      payment_days: days,
      notes: input.notes,
      is_active: !!input.isActive,
    },
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  return { ok: true, message: id ? "Supplier saved." : `${input.name.trim()} added.` };
}

export async function savePurchaseOrder(input: {
  id: string | null;
  supplierId: string;
  expectedOn: string;
  notes: string;
  lines: CleanLine[];
  place: boolean;
}): Promise<PurchaseResult> {
  // An empty or broken id would reach the database as a raw "invalid uuid" error, so stop it here in plain words.
  if (input.id !== null && !isUuid(input.id)) return { ok: false, error: "Purchase order not found." };
  if (!isUuid(input.supplierId)) return { ok: false, error: "Choose a supplier." };
  if (input.expectedOn && !isYmd(input.expectedOn)) return { ok: false, error: "Choose a valid expected date." };
  if (!Array.isArray(input.lines) || input.lines.length === 0) return { ok: false, error: "Add at least one ingredient." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_purchase_order", {
    p_id: input.id as string,
    p_supplier_id: input.supplierId,
    p_lines: input.lines as unknown as Json,
    p_expected_on: input.expectedOn || undefined,
    p_notes: input.notes || undefined,
    p_place: !!input.place,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  const r = (data ?? {}) as { number?: string };
  return { ok: true, message: input.place ? `Order ${r.number ?? ""} sent.` : `Order ${r.number ?? ""} saved as a draft.` };
}

/** Approves a draft purchase order at the next level that is waiting. */
export async function approvePurchaseOrder(id: string): Promise<PurchaseResult> {
  if (!isUuid(id)) return { ok: false, error: "Purchase order not found." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("approve_purchase_order", { p_id: id });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  const r = (data ?? {}) as { number?: string; level?: number; levels_left?: number };
  return { ok: true, message: r.levels_left && r.levels_left > 0 ? `Order ${r.number ?? ""} approved at level ${r.level}. ${r.levels_left} more level${r.levels_left === 1 ? "" : "s"} to go.` : `Order ${r.number ?? ""} approved at level ${r.level}. It can be sent now.` };
}

export async function setPurchaseOrderStatus(id: string, action: "order" | "cancel" | "close"): Promise<PurchaseResult> {
  if (action !== "order" && action !== "cancel" && action !== "close") return { ok: false, error: "Unknown action." };
  if (!isUuid(id)) return { ok: false, error: "Purchase order not found." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_purchase_order_status", { p_id: id, p_action: action });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  const number = ((data ?? {}) as { number?: string }).number ?? "";
  return {
    ok: true,
    message:
      action === "order"
        ? `Order ${number} sent.`
        : action === "cancel"
          ? `Order ${number} cancelled.`
          : `Order ${number} closed. Nothing more is expected on it.`,
  };
}

/**
 * Receives goods into stock. `clientRef` identifies this one receipt: sending
 * it again (a second tap, a retry after a dropped connection) returns the
 * receipt already saved instead of making another.
 */
export async function receiveGoods(input: {
  supplierId: string;
  purchaseOrderId: string | null;
  lines: CleanLine[];
  billNo: string;
  billDate: string;
  tax: number;
  other: number;
  paid: "no" | "full" | "part";
  amount: number;
  method: string;
  reference: string;
  fromTill: boolean;
  clientRef: string;
  /** Earlier receiving date (needs the back-dating right). */
  receivedOn?: string;
  receiptType?: string;
  distribute?: boolean;
}): Promise<ReceiveResult> {
  if (!isUuid(input.supplierId)) return { ok: false, error: "Choose a supplier." };
  if (input.purchaseOrderId && !isUuid(input.purchaseOrderId)) return { ok: false, error: "Purchase order not found." };
  if (!Array.isArray(input.lines) || input.lines.length === 0) return { ok: false, error: "Add at least one ingredient." };
  if (input.billDate && !isYmd(input.billDate)) return { ok: false, error: "Choose a valid bill date." };
  // Without this reference a second tap would save the delivery twice, so never send without it.
  if (!isUuid(input.clientRef)) return { ok: false, error: "This page is out of date. Refresh it and try again." };
  const tax = amountCents(input.tax);
  const other = amountCents(input.other);
  if (tax === null || other === null) return { ok: false, error: "Tax and other charges must be numbers of zero or more." };
  // The same sum the database does, so "Paid in full" pays exactly the total.
  const total = input.lines.reduce((s, l) => s + lineCents(l.qty, l.unit_cost) + lineTaxCents(l.qty, l.unit_cost, l.tax_rate), 0) + tax + other;

  let payment: Json | undefined;
  if (input.paid === "full" || input.paid === "part") {
    if (!isPayMethod(input.method)) return { ok: false, error: "Choose how the supplier was paid." };
    const cents = input.paid === "full" ? total : amountCents(input.amount);
    if (cents === null || (input.paid === "part" && cents <= 0)) return { ok: false, error: "Enter the amount paid." };
    if (cents > total) return { ok: false, error: "The amount paid cannot be more than the total." };
    if (cents > 0) {
      payment = {
        amount: cents / 100,
        method: input.method,
        reference: input.reference,
        from_till: input.method === "cash" && !!input.fromTill,
      };
    }
  }

  if (input.receivedOn && !isYmd(input.receivedOn)) return { ok: false, error: "Choose a valid receiving date." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("receive_goods", {
    p_supplier_id: input.supplierId,
    p_lines: input.lines as unknown as Json,
    p_purchase_order_id: input.purchaseOrderId || undefined,
    p_bill_no: input.billNo || undefined,
    p_bill_date: input.billDate || undefined,
    p_tax: tax / 100,
    p_other: other / 100,
    p_payment: payment,
    p_client_ref: input.clientRef,
    p_received_on: input.receivedOn || undefined,
    p_receipt_type: input.receiptType || "purchase",
    p_distribute: !!input.distribute,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  revalidatePath("/stock");
  if (payment) revalidatePath("/shift");
  const r = (data ?? {}) as { number?: string; total?: number | string; balance?: number | string; repeat?: boolean };
  return { ok: true, number: r.number ?? "", total: Number(r.total ?? 0), balance: Number(r.balance ?? 0), repeat: r.repeat === true };
}

/**
 * Records a payment to a supplier. `clientRef` identifies this one payment:
 * sending it again (a second tap, a retry after a dropped connection) returns
 * the payment already saved instead of paying again.
 */
export async function paySupplier(input: {
  receiptId: string;
  amount: number;
  method: string;
  reference: string;
  paidOn: string;
  fromTill: boolean;
  clientRef: string;
}): Promise<PayResult> {
  if (!isUuid(input.receiptId)) return { ok: false, error: "Goods receipt not found." };
  // Without this reference a second tap would pay the supplier twice, so never send without it.
  if (!isUuid(input.clientRef)) return { ok: false, error: "This page is out of date. Refresh it and try again." };
  if (!isPayMethod(input.method)) return { ok: false, error: "Choose how the supplier was paid." };
  const cents = amountCents(input.amount);
  if (cents === null || cents <= 0) return { ok: false, error: "Enter an amount greater than zero." };
  if (input.paidOn && !isYmd(input.paidOn)) return { ok: false, error: "Choose a valid payment date." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pay_supplier", {
    p_receipt_id: input.receiptId,
    p_amount: cents / 100,
    p_method: input.method,
    p_reference: input.reference || undefined,
    p_paid_on: input.paidOn || undefined,
    p_from_till: input.method === "cash" && !!input.fromTill,
    p_client_ref: input.clientRef,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  revalidatePath("/shift");
  const r = (data ?? {}) as { amount?: number | string; balance?: number | string };
  return { ok: true, amount: Number(r.amount ?? cents / 100), balance: Number(r.balance ?? 0) };
}

export type RefundResult = { ok: true; amount: number; left: number } | Fail;

/** Records money a supplier gave back after goods on a paid receipt were returned. */
export async function receiveSupplierRefund(input: {
  receiptId: string;
  amount: number;
  method: string;
  reference: string;
  receivedOn: string;
  intoTill: boolean;
  clientRef: string;
}): Promise<RefundResult> {
  if (!isUuid(input.receiptId)) return { ok: false, error: "Goods receipt not found." };
  if (!isUuid(input.clientRef)) return { ok: false, error: "This page is out of date. Refresh it and try again." };
  if (!isPayMethod(input.method)) return { ok: false, error: "Choose how the refund was received." };
  const cents = amountCents(input.amount);
  if (cents === null || cents <= 0) return { ok: false, error: "Enter an amount greater than zero." };
  if (input.receivedOn && !isYmd(input.receivedOn)) return { ok: false, error: "Choose a valid date." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("receive_supplier_refund", {
    p_receipt_id: input.receiptId,
    p_amount: cents / 100,
    p_method: input.method,
    p_reference: input.reference || undefined,
    p_received_on: input.receivedOn || undefined,
    p_into_till: input.method === "cash" && !!input.intoTill,
    p_client_ref: input.clientRef,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  revalidatePath("/shift");
  const r = (data ?? {}) as { amount?: number | string; left?: number | string };
  return { ok: true, amount: Number(r.amount ?? cents / 100), left: Number(r.left ?? 0) };
}

/**
 * Undoes a supplier payment that was entered wrongly. Nothing is deleted: the
 * database adds a matching negative entry and, for a payment from the till,
 * puts the cash back into the open drawer.
 */
export async function undoSupplierPayment(paymentId: string, reason: string): Promise<UndoPayResult> {
  if (!isUuid(paymentId)) return { ok: false, error: "Payment not found." };
  const why = String(reason ?? "").trim();
  if (why.length < 3) return { ok: false, error: "Write a short reason for undoing the payment." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("undo_supplier_payment", { p_payment_id: paymentId, p_reason: why });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  revalidatePath("/shift");
  const r = (data ?? {}) as { amount?: number | string; balance?: number | string; number?: string };
  return { ok: true, amount: Number(r.amount ?? 0), balance: Number(r.balance ?? 0), number: r.number ?? "" };
}


/** Owner setting: does the restaurant claim the tax on its purchases back from the tax office? */
export async function setInputTaxClaim(claim: boolean): Promise<PurchaseResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_input_tax_claim", { p_claim: !!claim });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  return { ok: true, message: claim ? "Purchase tax will be claimed back, not added to stock cost." : "Purchase tax will be added to stock cost." };
}

/** Block or unblock a supplier (a blocked supplier cannot get orders or deliveries). */
export async function setSupplierBlocked(id: string, blocked: boolean, reason: string): Promise<PurchaseResult> {
  if (!isUuid(id)) return { ok: false, error: "Supplier not found." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_supplier_blocked", { p_id: id, p_blocked: blocked, ...(reason.trim() ? { p_reason: reason.trim() } : {}) });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  return { ok: true, message: blocked ? "Supplier blocked." : "Supplier unblocked." };
}

export type AdvanceResult = { ok: true; number: string; amount: number; message: string } | Fail;
export type ApplyAdvanceResult = { ok: true; amount: number; advanceLeft: number; receiptBalance: number; number: string } | Fail;

/** Money given to a supplier before any bill: it sits on the supplier's account until it is used. */
export async function payAdvance(input: {
  supplierId: string;
  amount: number;
  method: string;
  reference: string;
  paidOn: string;
  fromTill: boolean;
  notes: string;
  clientRef: string;
}): Promise<AdvanceResult> {
  if (!isUuid(input.supplierId)) return { ok: false, error: "Choose a supplier." };
  // Without this reference a second tap would pay the supplier twice, so never send without it.
  if (!isUuid(input.clientRef)) return { ok: false, error: "This page is out of date. Refresh it and try again." };
  if (!isPayMethod(input.method)) return { ok: false, error: "Choose how the supplier was paid." };
  const cents = amountCents(input.amount);
  if (cents === null || cents <= 0) return { ok: false, error: "Enter an amount greater than zero." };
  if (input.paidOn && !isYmd(input.paidOn)) return { ok: false, error: "Choose a valid payment date." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("pay_supplier_advance", {
    p_supplier: input.supplierId,
    p_amount: cents / 100,
    p_method: input.method,
    p_reference: input.reference || undefined,
    p_paid_on: input.paidOn || undefined,
    p_from_till: input.method === "cash" && !!input.fromTill,
    p_notes: input.notes || undefined,
    p_client_ref: input.clientRef,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  revalidatePath("/shift");
  const r = (data ?? {}) as { number?: string; amount?: number | string };
  return { ok: true, number: r.number ?? "", amount: Number(r.amount ?? cents / 100), message: `Advance ${r.number ?? ""} saved.` };
}

/** Uses advance money against a bill. No cash moves now: it left when the advance was paid. */
export async function applyAdvance(input: { advanceId: string; receiptId: string; amount: number }): Promise<ApplyAdvanceResult> {
  if (!isUuid(input.advanceId)) return { ok: false, error: "Advance not found." };
  if (!isUuid(input.receiptId)) return { ok: false, error: "Choose the bill to use it on." };
  const cents = amountCents(input.amount);
  if (cents === null || cents <= 0) return { ok: false, error: "Enter an amount greater than zero." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("apply_supplier_advance", { p_advance: input.advanceId, p_receipt: input.receiptId, p_amount: cents / 100 });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  const r = (data ?? {}) as { amount?: number | string; advance_left?: number | string; receipt_balance?: number | string; number?: string };
  return { ok: true, amount: Number(r.amount ?? 0), advanceLeft: Number(r.advance_left ?? 0), receiptBalance: Number(r.receipt_balance ?? 0), number: r.number ?? "" };
}

/** Takes advance money back off a bill. It goes back onto the advance, not into the till. */
export async function unapplyAdvance(paymentId: string, reason: string): Promise<PurchaseResult> {
  if (!isUuid(paymentId)) return { ok: false, error: "Payment not found." };
  const why = String(reason ?? "").trim();
  if (why.length < 3) return { ok: false, error: "Write a short reason for taking the advance back off the bill." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("unapply_supplier_advance", { p_payment_id: paymentId, p_reason: why });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  const r = (data ?? {}) as { number?: string; receipt?: string };
  return { ok: true, message: `${r.number ?? "The advance"} is back on the supplier's account; ${r.receipt ?? "the bill"} is owed again.` };
}

/** The supplier gave the money back, or it was entered wrongly. Only while none of it is on a bill. */
export async function cancelAdvance(advanceId: string, reason: string): Promise<PurchaseResult> {
  if (!isUuid(advanceId)) return { ok: false, error: "Advance not found." };
  const why = String(reason ?? "").trim();
  if (why.length < 3) return { ok: false, error: "Write a short reason for cancelling the advance." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("cancel_supplier_advance", { p_advance: advanceId, p_reason: why });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  revalidatePath("/shift");
  const r = (data ?? {}) as { number?: string; to_till?: boolean };
  return { ok: true, message: `${r.number ?? "The advance"} is cancelled.${r.to_till ? " The cash is back in the drawer." : ""}` };
}

/** Correct the supplier's bill number, bill date or due date on a receipt (stock and money are not changed). */
export async function amendReceipt(input: { receiptId: string; billNo: string; billDate: string; dueOn: string; reason: string }): Promise<PurchaseResult> {
  if (!isUuid(input.receiptId)) return { ok: false, error: "Receipt not found." };
  if (input.billDate && !isYmd(input.billDate)) return { ok: false, error: "Choose a valid bill date." };
  if (input.dueOn && !isYmd(input.dueOn)) return { ok: false, error: "Choose a valid due date." };
  const why = String(input.reason ?? "").trim();
  if (why.length < 3) return { ok: false, error: "Write a short reason for the correction." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("amend_receipt_details", {
    p_receipt: input.receiptId,
    p_bill_no: input.billNo ?? "",
    p_bill_date: input.billDate || undefined,
    p_due_on: input.dueOn || undefined,
    p_reason: why,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/purchases");
  revalidatePath("/reports/supplier-ageing");
  const r = (data ?? {}) as { number?: string };
  return { ok: true, message: `${r.number ?? "Receipt"} corrected.` };
}
