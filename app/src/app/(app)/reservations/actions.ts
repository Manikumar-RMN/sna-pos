"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";

export async function saveBooking(input: { id: string | null; name: string; phone: string; party: number; when: string | null; tableId: string | null; note: string }) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("save_reservation", {
    p_id: input.id as unknown as string,
    p_name: input.name,
    p_phone: input.phone,
    p_party: input.party,
    p_when: input.when as unknown as string,
    p_table: input.tableId as unknown as string,
    p_note: input.note,
  });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath("/reservations");
  return { ok: true as const, message: input.when ? "Booking saved." : "Added to the waiting list." };
}

export async function setBookingStatus(id: string, status: string, tableId: string | null) {
  const supabase = await createClient();
  const { error } = await supabase.rpc("set_reservation_status", { p_id: id, p_status: status, p_table: tableId ?? undefined });
  if (error) return { ok: false as const, error: friendlyDbError(error) };
  revalidatePath("/reservations");
  return { ok: true as const };
}
