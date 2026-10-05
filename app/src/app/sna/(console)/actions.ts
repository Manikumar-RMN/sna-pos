"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";

export type SnaResult = { ok: true; message: string } | { ok: false; error: string };

function done(message: string, path = "/sna"): SnaResult {
  revalidatePath(path, "layout");
  return { ok: true, message };
}

export async function setEdition(restaurantId: string, edition: "basic" | "professional", note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_edition", { p_restaurant: restaurantId, p_edition: edition, p_note: note || undefined });
  if (error) return { ok: false, error: error.message };
  return done(edition === "professional" ? "Upgraded to Professional." : "Moved to Basic.");
}

export async function setModule(restaurantId: string, module: string, on: boolean, note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_module", { p_restaurant: restaurantId, p_module: module, p_on: on, p_note: note || undefined });
  if (error) return { ok: false, error: error.message };
  return done(on ? "Module switched on." : "Module switched off.");
}

export async function decideRequest(id: string, approve: boolean, note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_decide_request", { p_id: id, p_approve: approve, p_note: note || undefined });
  if (error) return { ok: false, error: error.message };
  return done(approve ? "Approved." : "Rejected.");
}

export async function createOutlet(input: {
  requestId: string;
  name: string;
  code: string;
  city: string;
  address: string;
  phone: string;
}): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_create_outlet", {
    p_request: input.requestId,
    p_name: input.name,
    p_code: input.code,
    p_city: input.city,
    p_address: input.address || undefined,
    p_phone: input.phone || undefined,
  });
  if (error) return { ok: false, error: error.message };
  return done("Outlet added. The owner can now see it.");
}

export async function addOutletRequest(restaurantId: string, name: string, city: string, note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_add_request", {
    p_restaurant: restaurantId,
    p_kind: "outlet",
    p_outlet_name: name,
    p_outlet_city: city || undefined,
    p_note: note || undefined,
  });
  if (error) return { ok: false, error: error.message };
  return done("Outlet request added. Sales approves it, then an implementer adds it.");
}

export async function saveStaff(email: string, fullName: string, role: string, active: boolean): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_save_staff", { p_email: email, p_full_name: fullName, p_role: role, p_active: active });
  if (error) return { ok: false, error: error.message };
  return done("Saved.");
}

export async function setPrice(item: string, currency: string, price: string): Promise<SnaResult> {
  const supabase = await createClient();
  const value = price.trim() === "" ? null : Number(price);
  if (value !== null && !Number.isFinite(value)) return { ok: false, error: "Enter a number." };
  const { error } = await supabase.rpc("sna_set_price", { p_item: item, p_currency: currency, p_price: value as number });
  if (error) return { ok: false, error: error.message };
  return done("Price saved.");
}

// ---------- Client book: licence, notes, contacts, sales history

const clientPath = (restaurantId: string) => `/sna/r/${restaurantId}`;
const dateOrNull = (v: string) => (/^\d{4}-\d{2}-\d{2}$/.test(v) ? v : null);

export async function saveAccount(input: {
  restaurantId: string;
  status: string;
  licenceStart: string;
  licenceExpiry: string;
  accountManager: string;
  salesPerson: string;
  supportPerson: string;
}): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_save_account", {
    p_restaurant: input.restaurantId,
    p_status: input.status,
    // The database takes "no date" as null; the generated types only allow a string here.
    p_licence_start: dateOrNull(input.licenceStart) as string,
    p_licence_expiry: dateOrNull(input.licenceExpiry) as string,
    p_account_manager: input.accountManager || undefined,
    p_sales_person: input.salesPerson || undefined,
    p_support_person: input.supportPerson || undefined,
  });
  if (error) return { ok: false, error: error.message };
  return done("Saved.", clientPath(input.restaurantId));
}

export async function addNote(restaurantId: string, kind: string, body: string, nextContact: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_add_note", {
    p_restaurant: restaurantId,
    p_kind: kind,
    p_body: body,
    p_next_contact: dateOrNull(nextContact) ?? undefined,
  });
  if (error) return { ok: false, error: error.message };
  return done(kind === "note" ? "Note added." : "Added, and marked as contacted today.", clientPath(restaurantId));
}

export async function setFollowUp(restaurantId: string, nextContact: string): Promise<SnaResult> {
  const supabase = await createClient();
  const date = dateOrNull(nextContact);
  const { error } = await supabase.rpc("sna_set_follow_up", { p_restaurant: restaurantId, p_next_contact: date as string });
  if (error) return { ok: false, error: error.message };
  return done(date ? "Follow-up date saved." : "Follow-up cleared.", clientPath(restaurantId));
}

export async function saveContact(input: {
  restaurantId: string;
  id: string | null;
  kind: string;
  fullName: string;
  jobTitle: string;
  phone: string;
  email: string;
}): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_save_contact", {
    p_restaurant: input.restaurantId,
    p_id: input.id as string,
    p_kind: input.kind,
    p_full_name: input.fullName,
    p_job_title: input.jobTitle || undefined,
    p_phone: input.phone || undefined,
    p_email: input.email || undefined,
  });
  if (error) return { ok: false, error: error.message };
  return done(input.id ? "Contact saved." : "Contact added.", clientPath(input.restaurantId));
}

export async function removeContact(restaurantId: string, id: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_remove_contact", { p_id: id });
  if (error) return { ok: false, error: error.message };
  return done("Contact removed.", clientPath(restaurantId));
}

export async function addSale(input: {
  restaurantId: string;
  kind: string;
  description: string;
  amount: string;
  saleDate: string;
  periodFrom: string;
  periodTo: string;
  invoiceNo: string;
  paidOn: string;
  note: string;
  extendLicence: boolean;
  /** What was bought: basic, professional, or add-on module keys. */
  modules: string[];
  /** Also switch on what was bought. */
  switchOn: boolean;
}): Promise<SnaResult> {
  const amount = Number(input.amount);
  if (input.amount.trim() === "" || !Number.isFinite(amount)) return { ok: false, error: "Enter the amount as a number." };
  const saleDate = dateOrNull(input.saleDate);
  if (!saleDate) return { ok: false, error: "Enter the sale date." };
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_record_sale", {
    p_restaurant: input.restaurantId,
    p_kind: input.kind,
    p_description: input.description,
    p_amount: amount,
    p_sale_date: saleDate,
    p_period_from: dateOrNull(input.periodFrom) ?? undefined,
    p_period_to: dateOrNull(input.periodTo) ?? undefined,
    p_invoice_no: input.invoiceNo || undefined,
    p_paid_on: dateOrNull(input.paidOn) ?? undefined,
    p_note: input.note || undefined,
    p_extend_licence: input.extendLicence,
    p_modules: input.modules,
    p_switch_on: input.switchOn && input.modules.length > 0,
  });
  if (error) return { ok: false, error: error.message };
  const did = [input.extendLicence ? "the licence end date moved" : "", input.switchOn && input.modules.length > 0 ? "what was bought switched on" : ""].filter(Boolean);
  return done(did.length ? `Sale recorded, ${did.join(" and ")}.` : "Sale recorded.", clientPath(input.restaurantId));
}

export async function setSalePaid(restaurantId: string, id: string, paidOn: string): Promise<SnaResult> {
  const supabase = await createClient();
  const date = dateOrNull(paidOn);
  const { error } = await supabase.rpc("sna_set_sale_paid", { p_id: id, p_paid_on: date as string });
  if (error) return { ok: false, error: error.message };
  return done(date ? "Marked paid." : "Marked not paid.", clientPath(restaurantId));
}

export async function cancelSale(restaurantId: string, id: string, reason: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_cancel_sale", { p_id: id, p_reason: reason });
  if (error) return { ok: false, error: error.message };
  return done("Entry cancelled. Check the licence end date is still right.", clientPath(restaurantId));
}

/** Renewal reminder shown to the restaurant: off once payment is in, or back on. */
export async function setReminder(restaurantId: string, on: boolean): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_reminder", { p_restaurant: restaurantId, p_on: on });
  if (error) return { ok: false, error: error.message };
  return done(on ? "Reminder switched on." : "Reminder switched off for this end date.", clientPath(restaurantId));
}
