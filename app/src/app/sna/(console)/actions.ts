"use server";

import { randomInt } from "node:crypto";
import { revalidatePath } from "next/cache";
import { createClient as createPlainClient } from "@supabase/supabase-js";
import { createConsoleClient as createClient } from "@/lib/supabase/server";

import { friendlyDbError } from "@/lib/db-error";
export type SnaResult = { ok: true; message: string } | { ok: false; error: string };

function done(message: string, path = "/sna"): SnaResult {
  revalidatePath(path, "layout");
  return { ok: true, message };
}

export async function setEdition(restaurantId: string, edition: "basic" | "professional", note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_edition", { p_restaurant: restaurantId, p_edition: edition, p_note: note || undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done(edition === "professional" ? "Upgraded to Professional." : "Moved to Basic.");
}

export async function setBusinessType(restaurantId: string, type: string, apply: boolean): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_business_type", { p_restaurant: restaurantId, p_type: type, p_apply: apply });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done(apply ? "Business type saved and its starting settings put on every outlet." : "Business type saved.");
}

export async function setModule(restaurantId: string, module: string, on: boolean, note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_module", { p_restaurant: restaurantId, p_module: module, p_on: on, p_note: note || undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done(on ? "Module switched on." : "Module switched off.");
}

export async function decideRequest(id: string, approve: boolean, note: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_decide_request", { p_id: id, p_approve: approve, p_note: note || undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
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
  if (error) return { ok: false, error: friendlyDbError(error) };
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
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done("Outlet request added. Sales approves it, then an implementer adds it.");
}

export async function saveStaff(email: string, fullName: string, role: string, active: boolean): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_save_staff", { p_email: email, p_full_name: fullName, p_role: role, p_active: active });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done("Saved.");
}

/** Easy to read out and type: no 0/O or 1/l/I. */
function snaTemporaryPassword() {
  const letters = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz";
  const digits = "23456789";
  const pick = (set: string, n: number) => Array.from({ length: n }, () => set[randomInt(set.length)]).join("");
  return `${pick(letters, 4)}-${pick(digits, 4)}-${pick(letters, 4)}`;
}

/**
 * An admin adds a new SNA person: a sign-in is made for the email with a temporary password,
 * then the person is added to the SNA staff. If the email already has a sign-in, only the
 * staff entry is made and the person keeps their own password.
 */
export async function addSnaStaff(email: string, fullName: string, role: string): Promise<SnaResult & { tempPassword?: string }> {
  const address = email.trim().toLowerCase();
  const plain = createPlainClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const temp = snaTemporaryPassword();
  const { data: made, error: signUpError } = await plain.auth.signUp({ email: address, password: temp });
  // Supabase answers an address that already has a sign-in with an empty identity list (or an error).
  const existed = !!signUpError || !made.user || (made.user.identities?.length ?? 0) === 0;
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_save_staff", { p_email: address, p_full_name: fullName.trim(), p_role: role, p_active: true });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/sna", "layout");
  if (existed) return { ok: true, message: "Added. This email already had a sign-in, so they use their own password." };
  return { ok: true, message: `Added. They sign in at the SNA console with ${address} and the temporary password ${temp}.`, tempPassword: temp };
}

export async function setPrice(item: string, currency: string, price: string): Promise<SnaResult> {
  const supabase = await createClient();
  const value = price.trim() === "" ? null : Number(price);
  if (value !== null && !Number.isFinite(value)) return { ok: false, error: "Enter a number." };
  const { error } = await supabase.rpc("sna_set_price", { p_item: item, p_currency: currency, p_price: value as number });
  if (error) return { ok: false, error: friendlyDbError(error) };
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
  if (error) return { ok: false, error: friendlyDbError(error) };
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
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done(kind === "note" ? "Note added." : "Added, and marked as contacted today.", clientPath(restaurantId));
}

export async function setFollowUp(restaurantId: string, nextContact: string): Promise<SnaResult> {
  const supabase = await createClient();
  const date = dateOrNull(nextContact);
  const { error } = await supabase.rpc("sna_set_follow_up", { p_restaurant: restaurantId, p_next_contact: date as string });
  if (error) return { ok: false, error: friendlyDbError(error) };
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
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done(input.id ? "Contact saved." : "Contact added.", clientPath(input.restaurantId));
}

export async function removeContact(restaurantId: string, id: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_remove_contact", { p_id: id });
  if (error) return { ok: false, error: friendlyDbError(error) };
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
  if (error) return { ok: false, error: friendlyDbError(error) };
  const did = [input.extendLicence ? "the licence end date moved" : "", input.switchOn && input.modules.length > 0 ? "what was bought switched on" : ""].filter(Boolean);
  return done(did.length ? `Sale recorded, ${did.join(" and ")}.` : "Sale recorded.", clientPath(input.restaurantId));
}

export async function setSalePaid(restaurantId: string, id: string, paidOn: string): Promise<SnaResult> {
  const supabase = await createClient();
  const date = dateOrNull(paidOn);
  const { error } = await supabase.rpc("sna_set_sale_paid", { p_id: id, p_paid_on: date as string });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done(date ? "Marked paid." : "Marked not paid.", clientPath(restaurantId));
}

export async function cancelSale(restaurantId: string, id: string, reason: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_cancel_sale", { p_id: id, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done("Entry cancelled. Check the licence end date is still right.", clientPath(restaurantId));
}

/** Renewal reminder shown to the restaurant: off once payment is in, or back on. */
export async function setReminder(restaurantId: string, on: boolean): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_reminder", { p_restaurant: restaurantId, p_on: on });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done(on ? "Reminder switched on." : "Reminder switched off for this end date.", clientPath(restaurantId));
}

// ---------- New client: the only way a restaurant is created

export type NewClientResult =
  | { ok: true; id: string; clientCode: string; tradingName: string; ownerEmail: string; tempPassword: string | null }
  | { ok: false; error: string };

/** Easy to read out and type: no 0/O, 1/I/L. Three groups of four, e.g. T7KM-9QXP-4HRA. */
function makeTempPassword(): string {
  const letters = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
  const group = () => Array.from({ length: 4 }, () => letters[randomInt(letters.length)]).join("");
  return `${group()}-${group()}-${group()}`;
}

export async function createClientAccount(input: {
  legalName: string;
  tradingName: string;
  ownerName: string;
  ownerEmail: string;
  countryCode: string;
  branchName: string;
  branchCode: string;
  taxNo: string;
  edition: string;
  licenceStart: string;
  licenceExpiry: string;
}): Promise<NewClientResult> {
  const supabase = await createClient();
  // Only SNA staff reach the steps below. (The database checks again.)
  const { data: me } = await supabase.rpc("sna_me");
  if (!me) return { ok: false, error: "Only SNA staff can do this." };

  const email = input.ownerEmail.trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return { ok: false, error: "Enter the owner's email address." };
  if (!input.legalName.trim() || !input.tradingName.trim() || !input.ownerName.trim()) {
    return { ok: false, error: "Fill in the business name, the display name and the owner's name." };
  }

  // 1. Make the owner's sign-in the normal way, without touching the SNA person's own session.
  //    If the address already has a sign-in, the next step takes it over safely or refuses.
  const tempPassword = makeTempPassword();
  const plain = createPlainClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { error: signUpError } = await plain.auth.signUp({ email, password: tempPassword });
  if (signUpError && signUpError.code !== "user_already_exists" && !/already (registered|exists)/i.test(signUpError.message)) {
    return { ok: false, error: `The owner's sign-in could not be made: ${signUpError.message}` };
  }

  // 2. Build the restaurant for that sign-in.
  const { data, error } = await supabase.rpc("sna_create_client", {
    p_owner_email: email,
    p_owner_name: input.ownerName,
    p_legal_name: input.legalName,
    p_trading_name: input.tradingName,
    p_country_code: input.countryCode,
    p_temp_password: tempPassword,
    p_branch_name: input.branchName || undefined,
    p_branch_code: input.branchCode || undefined,
    p_tax_registration_no: input.taxNo.trim() || undefined,
    p_edition: input.edition === "professional" ? "professional" : "basic",
    p_licence_start: dateOrNull(input.licenceStart) ?? undefined,
    p_licence_expiry: dateOrNull(input.licenceExpiry) ?? undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  const made = data as unknown as { id: string; client_code: string; owner_email: string; kept_password: boolean };
  revalidatePath("/sna", "layout");
  return {
    ok: true,
    id: made.id,
    clientCode: made.client_code,
    tradingName: input.tradingName.trim(),
    ownerEmail: made.owner_email,
    tempPassword: made.kept_password ? null : tempPassword,
  };
}

// ---------- Go-live and erasing a client's test data

export async function setLive(restaurantId: string, live: boolean, reason: string): Promise<SnaResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("sna_set_live", { p_restaurant: restaurantId, p_live: live, p_reason: reason || undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return done(live ? "Marked as Live. Its data can no longer be erased." : "Live taken off. Its data can be erased again.", clientPath(restaurantId));
}

export async function eraseData(input: {
  restaurantId: string;
  posTx: boolean;
  posMaster: boolean;
  stockTx: boolean;
  stockMaster: boolean;
  clientCode: string;
  reason: string;
}): Promise<SnaResult> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("sna_erase", {
    p_restaurant: input.restaurantId,
    p_pos_tx: input.posTx,
    p_pos_master: input.posMaster,
    p_stock_tx: input.stockTx,
    p_stock_master: input.stockMaster,
    p_client_code: input.clientCode,
    p_reason: input.reason,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  const rows = ((data as unknown as { rows?: Record<string, number> } | null)?.rows ?? {}) as Record<string, number>;
  const names: Record<string, string> = { pos_tx: "POS transactions", pos_master: "POS masters", stock_tx: "Stock transactions", stock_master: "Stock masters" };
  const said = Object.entries(rows)
    .map(([k, n]) => `${names[k] ?? k}: ${n}`)
    .join(", ");
  return done(`Erased. ${said || "Nothing was there to remove."}`, clientPath(input.restaurantId));
}
