"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import type { DaySheet, Folio, GuestRow, RoomCard, RoomTypeAvail } from "@/lib/fo";

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
  revalidatePath("/front-office/setup");
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
  revalidatePath("/front-office/setup");
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
  revalidatePath("/front-office/setup");
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
  const t = await supabase.from("fo_stays").select("id").eq("stay_no", toStayNo).maybeSingle();
  if (t.error) return { ok: false, error: friendlyDbError(t.error) };
  if (!t.data) return { ok: false, error: `No stay number ${toStayNo} was found.` };
  const { error } = await supabase.rpc("fo_move_charge", { p_charge: chargeId, p_to_stay: t.data.id, p_reason: reason });
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
