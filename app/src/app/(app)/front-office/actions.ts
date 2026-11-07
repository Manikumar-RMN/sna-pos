"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { Company, CompanyLedger, DaySheet, Folio, GroupView, GuestRow, Quote, RoomCard, RoomTypeAvail } from "@/lib/fo";

export type FoResult<T = Record<string, unknown>> = ({ ok: true; message?: string } & T) | { ok: false; error: string };

const touch = () => {
  revalidatePath("/front-office");
};

/** Rooms, the day sheet and room-type availability for the main screen. */
export async function loadBoard(): Promise<{ ok: true; rooms: RoomCard[]; sheet: DaySheet } | { ok: false; error: string }> {
  const supabase = await createClient();
  const [rooms, sheet] = await Promise.all([supabase.rpc("fo_room_board"), supabase.rpc("fo_day_sheet", {})]);
  if (rooms.error) return { ok: false, error: friendlyDbError(rooms.error) };
  if (sheet.error) return { ok: false, error: friendlyDbError(sheet.error) };
  return { ok: true, rooms: (rooms.data ?? []) as unknown as RoomCard[], sheet: sheet.data as unknown as DaySheet };
}

export async function checkAvailability(arrival: string, departure: string): Promise<FoResult<{ types: RoomTypeAvail[] }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_availability", { p_arrival: arrival, p_departure: departure });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return { ok: true, types: (data ?? []) as unknown as RoomTypeAvail[] };
}

/** Finds or creates the guest, then books the stay. One call from the form, so a half-saved booking cannot happen on a retry. */
export async function bookStay(input: {
  fullName: string;
  phone: string;
  roomTypeId: string;
  arrival: string;
  departure: string;
  rate: number | null;
  ratePlanId: string | null;
  adults: number;
  children: number;
  source: string;
  notes: string;
  clientRef: string;
  checkInNow: boolean;
}): Promise<FoResult<{ stayId: string; stayNo: number }>> {
  const supabase = await createClient();
  const g = await supabase.rpc("fo_save_guest", { p_full_name: input.fullName, p_phone: input.phone || undefined });
  if (g.error) return { ok: false, error: friendlyDbError(g.error) };
  const guestId = (g.data as unknown as { guest_id: string }).guest_id;
  const s = await supabase.rpc("fo_create_stay", {
    p_guest_id: guestId,
    p_room_type_id: input.roomTypeId,
    p_arrival: input.arrival,
    p_departure: input.departure,
    p_nightly_rate: input.rate ?? undefined,
    p_adults: input.adults,
    p_children: input.children,
    p_source: input.source,
    p_notes: input.notes || undefined,
    p_client_ref: input.clientRef,
    p_rate_plan_id: input.ratePlanId ?? undefined,
  });
  if (s.error) return { ok: false, error: friendlyDbError(s.error) };
  const stay = s.data as unknown as { stay_id: string; stay_no: number };
  if (input.checkInNow) {
    const c = await supabase.rpc("fo_check_in", { p_stay: stay.stay_id });
    if (c.error) {
      touch();
      return { ok: false, error: `Booked as stay ${stay.stay_no}, but check-in failed: ${friendlyDbError(c.error)}` };
    }
  }
  touch();
  return { ok: true, stayId: stay.stay_id, stayNo: stay.stay_no, message: `Stay ${stay.stay_no} booked.` };
}

/** The price list for one room type and dates: the standard rate plus every rate plan that can price every night. */
export async function quoteStay(roomTypeId: string, arrival: string, departure: string, adults: number, children: number): Promise<FoResult<{ quote: Quote }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_quote", { p_room_type: roomTypeId, p_arrival: arrival, p_departure: departure, p_adults: adults, p_children: children });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return { ok: true, quote: data as unknown as Quote };
}

export async function checkIn(stayId: string, roomId: string | null): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_check_in", { p_stay: stayId, p_room_id: roomId ?? undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: "Checked in." };
}

export async function setRoomStatus(roomId: string, patch: { housekeeping?: "clean" | "dirty" | "inspected"; outOfService?: boolean; reason?: string }): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_set_room_status", {
    p_room: roomId,
    p_housekeeping: patch.housekeeping,
    p_out_of_service: patch.outOfService,
    p_reason: patch.reason,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  return { ok: true };
}

export async function cancelStay(stayId: string, reason: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_cancel_stay", { p_stay: stayId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: "Reservation cancelled." };
}

export async function markNoShow(stayId: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_mark_no_show", { p_stay: stayId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  return { ok: true, message: "Marked as no-show." };
}

export async function runNightAudit(): Promise<FoResult<{ summary: Record<string, unknown> }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_night_audit_run", {});
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  const summary = data as unknown as Record<string, unknown>;
  return { ok: true, summary, message: summary.repeat ? "That night was already audited." : "Night audit done." };
}

// ---- guest folio

export async function loadFolio(stayId: string): Promise<Folio | null> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("fo_folio", { p_stay: stayId });
  return (data as unknown as Folio | null) ?? null;
}

export async function postCharge(stayId: string, kind: string, description: string, amount: number, quantity: number, clientRef: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_post_charge", {
    p_stay: stayId, p_kind: kind, p_description: description, p_unit_amount: amount, p_quantity: quantity, p_client_ref: clientRef,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: "Charge posted." };
}

export async function voidCharge(stayId: string, chargeId: string, reason: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_void_charge", { p_charge: chargeId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: "Charge voided." };
}

export async function takePayment(stayId: string, amount: number, methodId: string | null, isRefund: boolean, clientRef: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_take_payment", {
    p_stay: stayId, p_amount: amount, p_payment_method_id: methodId ?? undefined, p_is_refund: isRefund, p_client_ref: clientRef,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: isRefund ? "Refund recorded." : "Payment recorded." };
}

export async function voidPayment(stayId: string, paymentId: string, reason: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_void_payment", { p_payment: paymentId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: "Payment voided." };
}

export async function checkOut(stayId: string, methodId: string | null, clientRef: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_check_out", { p_stay: stayId, p_payment_method_id: methodId ?? undefined, p_client_ref: clientRef });
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: "Checked out." };
}

// ---- setup

export async function saveRoomType(input: { id: string | null; code: string; name: string; baseRate: number; maxOccupancy: number; active: boolean }): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_save_room_type", {
    p_room_type_id: input.id ?? undefined, p_code: input.code, p_name: input.name,
    p_base_rate: input.baseRate, p_max_occupancy: input.maxOccupancy, p_active: input.active,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/front-office");
  touch();
  return { ok: true, message: "Room type saved." };
}

export async function saveRoom(input: { id: string | null; roomNumber: string; roomTypeId: string; floor: string; active: boolean }): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_save_room", {
    p_room_id: input.id ?? undefined, p_room_number: input.roomNumber, p_room_type_id: input.roomTypeId,
    p_floor_label: input.floor || undefined, p_active: input.active,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/front-office");
  touch();
  return { ok: true, message: "Room saved." };
}

export async function saveTaxSettings(input: { roomTax: number; roomTaxHigh: number; threshold: number; otherTax: number }): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_save_settings", {
    p_room_tax_pct: input.roomTax, p_room_tax_pct_high: input.roomTaxHigh,
    p_room_tax_threshold: input.threshold, p_other_tax_pct: input.otherTax,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/front-office");
  return { ok: true, message: "Tax settings saved." };
}

export async function assignRooms(roomIds: string[], attendantId: string | null, note: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_hk_assign", { p_rooms: roomIds, p_attendant: attendantId as unknown as string, p_note: note || undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/front-office/housekeeping");
  return { ok: true, message: "Rooms assigned." };
}

export async function amendStay(stayId: string, departure: string | null, rate: number | null, reason: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_amend_stay", {
    p_stay: stayId, p_departure: departure ?? undefined, p_nightly_rate: rate ?? undefined, p_reason: reason,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: "Stay changed." };
}

/** Moves a charge to the folio of another stay, found by its stay number. */
export async function moveCharge(stayId: string, chargeId: string, toStayNo: number, reason: string): Promise<FoResult> {
  const supabase = await createClient();
  const t = await supabase.rpc("fo_stay_by_no", { p_stay_no: toStayNo });
  if (t.error) return { ok: false, error: friendlyDbError(t.error) };
  if (!t.data) return { ok: false, error: `No stay number ${toStayNo} was found.` };
  const { error } = await supabase.rpc("fo_move_charge", { p_charge: chargeId, p_to_stay: t.data, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: `Moved to stay ${toStayNo}.` };
}

export async function findGuests(query: string): Promise<FoResult<{ guests: GuestRow[] }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_find_guests", { p_query: query });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return { ok: true, guests: (data ?? []) as unknown as GuestRow[] };
}

export async function setGuestFlags(guestId: string, patch: { vip?: boolean; preferences?: string; blocked?: boolean; blockedReason?: string }): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_set_guest_flags", {
    p_guest: guestId, p_vip: patch.vip, p_preferences: patch.preferences, p_blocked: patch.blocked, p_blocked_reason: patch.blockedReason,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  return { ok: true, message: "Guest updated." };
}

// ---- rate plans, business details and the tax invoice

export async function saveRatePlan(input: { id: string | null; code: string; name: string; mealPlan: string; description: string; active: boolean }): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_save_rate_plan", {
    p_plan_id: input.id ?? undefined, p_code: input.code, p_name: input.name, p_meal_plan: input.mealPlan,
    p_description: input.description || undefined, p_active: input.active,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/front-office");
  return { ok: true, message: "Rate plan saved." };
}

export async function saveRateRule(input: {
  planId: string; roomTypeId: string; rate: number; weekendRate: number | null; singleRate: number | null;
  includedAdults: number; extraAdult: number; extraChild: number; validFrom: string | null; validTo: string | null;
}): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_save_rate_rule", {
    p_plan_id: input.planId, p_room_type_id: input.roomTypeId, p_rate: input.rate,
    p_weekend_rate: input.weekendRate ?? undefined, p_single_rate: input.singleRate ?? undefined,
    p_included_adults: input.includedAdults, p_extra_adult: input.extraAdult, p_extra_child: input.extraChild,
    p_valid_from: input.validFrom ?? undefined, p_valid_to: input.validTo ?? undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/front-office");
  return { ok: true, message: "Rate saved." };
}

export async function deleteRateRule(ruleId: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_delete_rate_rule", { p_rule_id: ruleId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/front-office");
  return { ok: true, message: "Rate removed. Stays already booked keep their rates." };
}

export async function saveBusiness(input: {
  legalName: string; gstin: string; stateCode: string; address: string; phone: string; email: string;
  invoicePrefix: string; invoiceFooter: string; noGstBelow: number;
}): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_save_business", {
    p_legal_name: input.legalName, p_gstin: input.gstin, p_state_code: input.stateCode, p_address: input.address,
    p_phone: input.phone, p_email: input.email, p_invoice_prefix: input.invoicePrefix, p_invoice_footer: input.invoiceFooter,
    p_room_tax_exempt_below: input.noGstBelow,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/settings/front-office");
  return { ok: true, message: "Business details saved." };
}

export async function issueInvoice(stayId: string, billTo: { name: string; gstin: string; address: string; stateCode: string }, party: "guest" | "company" = "guest"): Promise<FoResult<{ invoiceNo: string }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_issue_invoice", {
    p_stay: stayId, p_party: party, p_bill_to_name: billTo.name || undefined, p_bill_to_gstin: billTo.gstin || undefined,
    p_bill_to_address: billTo.address || undefined, p_bill_to_state_code: billTo.stateCode || undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  const r = data as unknown as { invoice_no: string };
  return { ok: true, invoiceNo: r.invoice_no, message: `Invoice ${r.invoice_no} issued.` };
}

export async function reopenStay(stayId: string, reason: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_reopen_stay", { p_stay: stayId, p_reason: reason.trim() });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  touch();
  return { ok: true, message: "Stay reopened. The old invoice is cancelled; check out again to issue a new one." };
}

export async function reissueInvoice(stayId: string, invoiceId: string, reason: string, billTo: { name: string; gstin: string; address: string; stateCode: string }): Promise<FoResult<{ invoiceNo: string }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_reissue_invoice", {
    p_invoice: invoiceId, p_reason: reason.trim(), p_bill_to_name: billTo.name.trim() || undefined, p_bill_to_gstin: billTo.gstin.trim().toUpperCase() || undefined,
    p_bill_to_address: billTo.address.trim() || undefined, p_bill_to_state_code: billTo.stateCode.trim() || undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  const r = data as unknown as { old_invoice_no: string; credit_note_no: string; invoice_no: string };
  return { ok: true, invoiceNo: r.invoice_no, message: `${r.old_invoice_no} cancelled with credit note ${r.credit_note_no}. New invoice ${r.invoice_no} issued.` };
}

// ------------------------------------------------------------------ group bookings
export type GroupRoomLine = { roomTypeId: string; qty: number; adults: number; children: number; ratePlanId: string | null; rate: number | null };
const linesJson = (lines: GroupRoomLine[]) =>
  lines.map((l) => ({ room_type_id: l.roomTypeId, qty: l.qty, adults: l.adults, children: l.children, rate_plan_id: l.ratePlanId, rate: l.rate }));

export async function createGroup(input: {
  name: string; contactName: string; contactPhone: string; arrival: string; departure: string; notes: string; rooms: GroupRoomLine[]; clientRef: string;
}): Promise<FoResult<{ groupId: string }>> {
  const supabase = await createClient();
  const g = await supabase.rpc("fo_save_guest", { p_full_name: input.contactName, p_phone: input.contactPhone || undefined });
  if (g.error) return { ok: false, error: friendlyDbError(g.error) };
  const guestId = (g.data as unknown as { guest_id: string }).guest_id;
  const r = await supabase.rpc("fo_create_group", {
    p_name: input.name, p_contact_guest: guestId, p_arrival: input.arrival, p_departure: input.departure,
    p_rooms: linesJson(input.rooms), p_notes: input.notes || undefined, p_client_ref: input.clientRef,
  });
  if (r.error) return { ok: false, error: friendlyDbError(r.error) };
  touch();
  revalidatePath("/front-office/groups");
  const d = r.data as unknown as { group_id: string; group_no: number };
  return { ok: true, groupId: d.group_id, message: `Group #${d.group_no} booked.` };
}

export async function addGroupRooms(groupId: string, rooms: GroupRoomLine[]): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_group_add_rooms", { p_group: groupId, p_rooms: linesJson(rooms) });
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  revalidatePath(`/front-office/groups/${groupId}`);
  return { ok: true, message: "Rooms added to the group." };
}

/** Puts a real guest (found or created by name and phone) on one reserved room of a group. */
export async function setStayGuest(groupId: string, stayId: string, fullName: string, phone: string): Promise<FoResult> {
  const supabase = await createClient();
  const g = await supabase.rpc("fo_save_guest", { p_full_name: fullName, p_phone: phone || undefined });
  if (g.error) return { ok: false, error: friendlyDbError(g.error) };
  const guestId = (g.data as unknown as { guest_id: string }).guest_id;
  const { error } = await supabase.rpc("fo_set_stay_guest", { p_stay: stayId, p_guest: guestId });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/groups/${groupId}`);
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: "Guest saved on the room." };
}

export async function cancelGroup(groupId: string, reason: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_cancel_group", { p_group: groupId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  touch();
  revalidatePath("/front-office/groups");
  revalidatePath(`/front-office/groups/${groupId}`);
  return { ok: true, message: "Group cancelled." };
}

export async function loadGroup(groupId: string): Promise<GroupView | null> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("fo_group_view", { p_group: groupId });
  return (data as unknown as GroupView | null) ?? null;
}

// ------------------------------------------------------------------ companies (bill to company)
export async function saveCompany(input: {
  id: string | null; name: string; gstin: string; stateCode: string; address: string; contactName: string; phone: string; email: string;
  creditDays: number; creditLimit: number | null; active: boolean;
}): Promise<FoResult<{ companyId: string }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_save_company", {
    p_name: input.name, p_gstin: input.gstin || undefined, p_state_code: input.stateCode || undefined, p_address: input.address || undefined,
    p_contact_name: input.contactName || undefined, p_phone: input.phone || undefined, p_email: input.email || undefined,
    p_credit_days: input.creditDays, p_credit_limit: input.creditLimit ?? undefined, p_active: input.active, p_company_id: input.id ?? undefined,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/front-office/companies");
  return { ok: true, companyId: (data as unknown as { company_id: string }).company_id, message: "Company saved." };
}

export async function loadCompanies(): Promise<Company[]> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("fo_companies_list", { p_include_inactive: false });
  return (data ?? []) as unknown as Company[];
}

/** Links a stay to a company (scope "room" or "all"), or unlinks it when companyId is null. */
export async function setStayCompany(stayId: string, companyId: string | null, scope: "room" | "all"): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_set_stay_company", { p_stay: stayId, p_company: companyId ?? undefined, p_scope: scope });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: companyId ? "Company set on the stay." : "Company removed from the stay." };
}

export async function setGroupCompany(groupId: string, companyId: string | null, scope: "room" | "all"): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_set_group_company", { p_group: groupId, p_company: companyId ?? undefined, p_scope: scope });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/groups/${groupId}`);
  return { ok: true, message: companyId ? "Company set on every open room of the group." : "Company removed from the group's open rooms." };
}

export async function takeCompanyPayment(companyId: string, amount: number, methodId: string | null, reference: string, clientRef: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_take_company_payment", {
    p_company: companyId, p_amount: amount, p_payment_method_id: methodId ?? undefined, p_reference: reference || undefined, p_client_ref: clientRef,
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/companies/${companyId}`);
  revalidatePath("/front-office/companies");
  return { ok: true, message: "Payment recorded." };
}

export async function voidCompanyPayment(companyId: string, paymentId: string, reason: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_void_company_payment", { p_payment: paymentId, p_reason: reason });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/companies/${companyId}`);
  revalidatePath("/front-office/companies");
  return { ok: true, message: "Payment voided." };
}

export async function loadCompanyLedger(companyId: string): Promise<CompanyLedger | null> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("fo_company_ledger", { p_company: companyId });
  return (data as unknown as CompanyLedger | null) ?? null;
}

// ------------------------------------------------------------------ requests, messages, wake-up calls
export async function addRequest(stayId: string, kind: "request" | "message" | "wakeup", text: string, dueDate?: string, dueTime?: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_add_request", {
    p_stay: stayId, p_kind: kind, p_text: text, p_due_date: dueDate || undefined, p_due_time: dueTime || undefined, p_client_ref: crypto.randomUUID(),
  });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/front-office/requests");
  return { ok: true, message: kind === "wakeup" ? "Wake-up call saved." : kind === "message" ? "Message saved." : "Request saved." };
}

export async function closeRequest(requestId: string, status: "done" | "cancelled", note?: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_close_request", { p_request: requestId, p_status: status, p_note: note || undefined });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath("/front-office/requests");
  return { ok: true, message: status === "done" ? "Marked done." : "Cancelled." };
}

// ------------------------------------------------------------------ credit notes and stay fees
export async function issueCreditNote(invoiceId: string, stayId: string, reason: string, lines: { sac: string; tax_pct: number; taxable: number }[], clientRef: string): Promise<FoResult<{ noteId: string }>> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("fo_issue_credit_note", { p_invoice: invoiceId, p_reason: reason, p_lines: lines, p_client_ref: clientRef });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}/invoice`);
  const r = data as unknown as { note_id: string; note_no: string };
  return { ok: true, noteId: r.note_id, message: `Credit note ${r.note_no} issued.` };
}

export async function postStayFee(stayId: string, fee: "early_checkin" | "late_checkout", percent: number, clientRef: string): Promise<FoResult> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("fo_post_stay_fee", { p_stay: stayId, p_fee: fee, p_percent: percent, p_client_ref: clientRef });
  if (error) return { ok: false, error: friendlyDbError(error) };
  revalidatePath(`/front-office/stay/${stayId}`);
  return { ok: true, message: fee === "late_checkout" ? "Late check-out fee posted." : "Early check-in fee posted." };
}
