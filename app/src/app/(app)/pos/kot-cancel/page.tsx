import Link from "next/link";
import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { dateTime } from "@/lib/format";
import { KotCancelList, type KotRow } from "./kot-cancel-list";

export default async function KotCancelPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { data: tickets } = await supabase
    .from("kitchen_tickets")
    .select("id, order_id, ticket_number, status, created_at")
    .neq("status", "cancelled")
    .gte("created_at", since)
    .order("created_at", { ascending: false })
    .limit(200);
  const orderIds = [...new Set((tickets ?? []).map((t) => t.order_id))];
  const { data: orders } = orderIds.length
    ? await supabase.from("orders").select("id, bill_number, payment_status, dining_tables!orders_dining_table_id_fkey(table_number)").in("id", orderIds)
    : { data: [] as never[] };
  const byId = new Map((orders ?? []).map((o) => [o.id, o]));
  const rows: KotRow[] = (tickets ?? []).map((t) => {
    const o = byId.get(t.order_id) as unknown as { bill_number: string; payment_status: string; dining_tables: { table_number: string } | { table_number: string }[] | null } | undefined;
    const tb = Array.isArray(o?.dining_tables) ? o?.dining_tables[0] : o?.dining_tables;
    return {
      id: t.id,
      table: tb?.table_number ?? "Counter",
      kot: String(t.ticket_number),
      bill: o?.bill_number ?? "",
      paid: o?.payment_status === "paid",
      status: t.status,
      at: dateTime(t.created_at, user.timezone),
    };
  });
  return (
    <div className="mx-auto max-w-2xl">
      <div className="mb-3 flex items-center justify-between">
        <h1 className="text-lg font-bold">KOT cancellation</h1>
        <Link href="/pos" className="btn border text-sm" style={{ borderColor: "var(--color-line)" }}>
          ← Back
        </Link>
      </div>
      <p className="mb-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Kitchen tickets of the last 24 hours. Pick one, write the reason and cancel it. A ticket on a paid bill cannot be cancelled here.
      </p>
      <KotCancelList rows={rows} />
    </div>
  );
}
