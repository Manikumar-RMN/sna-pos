import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { Bookings } from "./bookings";

export default async function ReservationsPage() {
  const user = await requireUser();
  if (!has(user, "reservations")) {
    return <p className="card p-5 text-sm">Reservations and waitlist is part of the Professional edition. Ask for it in Settings → Plan and modules.</p>;
  }
  const supabase = await createClient();
  const since = new Date(Date.now() - 6 * 3600 * 1000).toISOString();
  const [{ data: rows }, { data: tables }] = await Promise.all([
    supabase
      .from("reservations")
      .select("id, guest_name, phone, party_size, reserved_for, status, note, created_at, dining_table_id")
      .or(`reserved_for.gte.${since},and(reserved_for.is.null,created_at.gte.${new Date(Date.now() - 24 * 3600 * 1000).toISOString()})`)
      .order("reserved_for", { ascending: true, nullsFirst: false })
      .order("created_at")
      .limit(200),
    supabase.from("dining_tables").select("id, table_number").eq("is_active", true).order("table_number"),
  ]);
  return (
    <Bookings
      canEdit={can(user, "order.create")}
      timezone={user.timezone}
      country={user.country_code}
      restaurant={user.trading_name}
      whatsapp
      tables={(tables ?? []).map((t) => ({ id: t.id, number: t.table_number }))}
      rows={(rows ?? []).map((r) => ({
        id: r.id,
        name: r.guest_name,
        phone: r.phone,
        party: r.party_size,
        when: r.reserved_for,
        status: r.status as "booked" | "waiting" | "seated" | "cancelled" | "no_show",
        note: r.note,
        createdAt: r.created_at,
        tableId: r.dining_table_id,
      }))}
    />
  );
}
