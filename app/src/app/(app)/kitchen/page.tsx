import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { orderTypeLabel } from "@/lib/format";
import { billFormat, paperWidth } from "@/lib/bill-format";
import { KitchenBoard, type ServedTicket, type Ticket } from "./kitchen-board";

const TICKET_COLUMNS = "id, order_id, ticket_number, station, status, created_at, started_at, ready_at, printed_at, changed_at, kitchen_seen_at, cancel_reason";

export default async function KitchenPage() {
  const user = await requireUser();
  const supabase = await createClient();
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const servedSince = new Date(Date.now() - 2 * 3600 * 1000).toISOString();

  const [{ data: tickets }, { data: servedRows }, { data: settings }, { data: cancelledRows }] = await Promise.all([
    supabase
      .from("kitchen_tickets")
      .select(TICKET_COLUMNS)
      .in("status", ["new", "preparing", "ready"])
      .gte("created_at", since)
      .order("created_at"),
    // Served a short while ago: kept so a ticket marked "Served" by mistake can be brought back.
    supabase
      .from("kitchen_tickets")
      .select(TICKET_COLUMNS)
      .eq("status", "served")
      .gte("ready_at", servedSince)
      .order("ready_at", { ascending: false })
      .limit(20),
    supabase.from("branch_settings").select("bill_format").eq("branch_id", user.branch_id).maybeSingle(),
    // Cancelled by the waiter and not yet acknowledged: shown in red until the kitchen taps "Seen".
    supabase
      .from("kitchen_tickets")
      .select(TICKET_COLUMNS)
      .eq("status", "cancelled")
      .is("kitchen_seen_at", null)
      .gte("created_at", since)
      .order("created_at"),
  ]);

  const all = [...(tickets ?? []), ...(servedRows ?? []), ...(cancelledRows ?? [])];
  const ids = all.map((t) => t.id);
  const orderIds = [...new Set(all.map((t) => t.order_id))];
  const [{ data: items }, { data: orders }] = await Promise.all([
    ids.length
      ? supabase
          .from("kitchen_ticket_items")
          .select("kitchen_ticket_id, product_name, product_name_local, quantity, note, status, change_text")
          .in("kitchen_ticket_id", ids)
      : Promise.resolve({ data: [] as { kitchen_ticket_id: string; product_name: string; product_name_local: string | null; quantity: number; note: string | null; status: string; change_text: string | null }[] }),
    orderIds.length
      ? supabase.from("orders").select("id, order_type, dining_table_id, bill_number, token_no, guest_name").in("id", orderIds)
      : Promise.resolve({ data: [] as { id: string; order_type: string; dining_table_id: string | null; bill_number: string; token_no: number | null; guest_name: string | null }[] }),
  ]);
  const tableIds = [...new Set((orders ?? []).map((o) => o.dining_table_id).filter(Boolean))] as string[];
  const { data: tables } = tableIds.length
    ? await supabase.from("dining_tables").select("id, table_number").in("id", tableIds)
    : { data: [] as { id: string; table_number: string }[] };
  const tableNo = new Map((tables ?? []).map((t) => [t.id, t.table_number]));
  const orderMap = new Map((orders ?? []).map((o) => [o.id, o]));

  /** Everything a ticket shows, apart from where it stands on the board. */
  const details = (t: NonNullable<typeof tickets>[number]) => {
    const o = orderMap.get(t.order_id);
    const table = o?.dining_table_id ? tableNo.get(o.dining_table_id) : null;
    const type = orderTypeLabel[o?.order_type ?? ""] ?? "";
    // Takeaway and delivery are called by the guest's name; a table is called by its number.
    const guest = o && (o.order_type === "takeaway" || o.order_type === "delivery") ? (o.guest_name ?? "").trim() : "";
    return {
      id: t.id,
      number: t.ticket_number,
      createdAt: t.created_at,
      where: table ? `Table ${table}` : guest ? `${type} · ${guest}` : type,
      token: o?.token_no ?? null,
      station: t.station ?? "Kitchen",
      printedAt: t.printed_at,
      bill: o?.bill_number ?? "",
      items: (items ?? [])
        .filter((i) => i.kitchen_ticket_id === t.id)
        .map((i) => ({ name: i.product_name, local: i.product_name_local, qty: Number(i.quantity), note: i.note, cancelled: i.status === "cancelled", changeText: i.change_text })),
    };
  };

  const board: Ticket[] = [
    ...(tickets ?? []).map((t) => ({
      ...details(t),
      status: t.status as Ticket["status"],
      changed: !!t.changed_at && !t.kitchen_seen_at,
    })),
    ...(cancelledRows ?? []).map((t) => ({ ...details(t), status: "cancelled" as const, cancelReason: t.cancel_reason, changed: false })),
  ];
  const served: ServedTicket[] = (servedRows ?? []).map((t) => ({ ...details(t), readyAt: t.ready_at }));

  // Settings → Bill layout: paper roll width and the size of the text on the kitchen ticket.
  const format = billFormat(settings?.bill_format);

  return (
    <div>
      <div className="mb-4 flex items-end justify-between">
        <div>
          <h1 className="text-xl font-bold tracking-tight">Kitchen</h1>
          <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Every bill sends a ticket to its station. Tap to move it along. Refreshes every 10 seconds.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <a href="/batches" className="btn border text-sm" style={{ borderColor: "var(--color-line)" }}>
            Batches made
          </a>
          <a href="/ready" target="_blank" rel="noreferrer" className="btn border text-sm" style={{ borderColor: "var(--color-line)" }}>
            Order-ready screen
          </a>
        </div>
      </div>
      <KitchenBoard
        tickets={board}
        served={served}
        timezone={user.timezone}
        printMm={paperWidth(format).printMm}
        largePrint={format.kot_text === "large"}
      />
    </div>
  );
}
