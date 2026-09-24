import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { orderTypeLabel } from "@/lib/format";
import { KitchenBoard, type Ticket } from "./kitchen-board";

export default async function KitchenPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();

  const { data: tickets } = await supabase
    .from("kitchen_tickets")
    .select("id, order_id, ticket_number, status, created_at, started_at, ready_at")
    .in("status", ["new", "preparing", "ready"])
    .gte("created_at", since)
    .order("created_at");

  const ids = (tickets ?? []).map((t) => t.id);
  const orderIds = (tickets ?? []).map((t) => t.order_id);
  const [{ data: items }, { data: orders }] = await Promise.all([
    ids.length
      ? supabase
          .from("kitchen_ticket_items")
          .select("kitchen_ticket_id, product_name, quantity, note, status")
          .in("kitchen_ticket_id", ids)
      : Promise.resolve({ data: [] as { kitchen_ticket_id: string; product_name: string; quantity: number; note: string | null; status: string }[] }),
    orderIds.length
      ? supabase.from("orders").select("id, order_type, dining_table_id").in("id", orderIds)
      : Promise.resolve({ data: [] as { id: string; order_type: string; dining_table_id: string | null }[] }),
  ]);
  const tableIds = [...new Set((orders ?? []).map((o) => o.dining_table_id).filter(Boolean))] as string[];
  const { data: tables } = tableIds.length
    ? await supabase.from("dining_tables").select("id, table_number").in("id", tableIds)
    : { data: [] as { id: string; table_number: string }[] };
  const tableNo = new Map((tables ?? []).map((t) => [t.id, t.table_number]));
  const orderMap = new Map((orders ?? []).map((o) => [o.id, o]));

  const board: Ticket[] = (tickets ?? []).map((t) => {
    const o = orderMap.get(t.order_id);
    const table = o?.dining_table_id ? tableNo.get(o.dining_table_id) : null;
    return {
      id: t.id,
      number: t.ticket_number,
      status: t.status as Ticket["status"],
      createdAt: t.created_at,
      where: table ? `Table ${table}` : orderTypeLabel[o?.order_type ?? ""] ?? "",
      items: (items ?? [])
        .filter((i) => i.kitchen_ticket_id === t.id && i.status !== "cancelled")
        .map((i) => ({ name: i.product_name, qty: Number(i.quantity), note: i.note })),
    };
  });

  return (
    <div>
      <div className="mb-4 flex items-end justify-between">
        <div>
          <h1 className="text-xl font-bold tracking-tight">Kitchen</h1>
          <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Every bill sends a ticket here. Tap to move it along. Refreshes every 15 seconds.
          </p>
        </div>
      </div>
      <KitchenBoard tickets={board} timezone={user.timezone} />
    </div>
  );
}
