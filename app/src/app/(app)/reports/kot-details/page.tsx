import { addDays, dateTime, localDayStartIso } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/** KOT details (Winsar "KOT Details"): every kitchen ticket sent in the period with its items and state. */
type Row = {
  id: string;
  ticket_number: string;
  created_at: string;
  status: string;
  station: string | null;
  cancel_reason: string | null;
  branch_id: string;
  orders: { bill_number: string | null; dining_tables: { table_number: string } | null } | null;
  kitchen_ticket_items: { product_name: string; quantity: number; status: string | null }[];
};
const LIMIT = 500;

export default async function KotDetailsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "KOT details" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const tz = user.timezone;
  let q = supabase
    .from("kitchen_tickets")
    .select("id, ticket_number, created_at, status, station, cancel_reason, branch_id, orders(bill_number, dining_tables(table_number)), kitchen_ticket_items(product_name, quantity, status)")
    .gte("created_at", localDayStartIso(from, tz))
    .lt("created_at", localDayStartIso(addDays(to, 1), tz));
  if (scope.branchId) q = q.eq("branch_id", scope.branchId);
  const { data, error } = await q.order("created_at", { ascending: false }).limit(LIMIT);
  const rows = (error ? [] : (data ?? [])) as unknown as Row[];
  const head = ["Time", "KOT no", "Bill", "Table", ...(scope.all ? ["Outlet"] : []), "Station", "Status", "Items"];
  const items = (x: Row) => x.kitchen_ticket_items.map((i) => `${Number(i.quantity)} × ${i.product_name}${i.status === "cancelled" ? " (cancelled)" : ""}`).join(", ");
  const table = rows.map((x) => [
    dateTime(x.created_at, tz),
    x.ticket_number,
    x.orders?.bill_number ?? "—",
    x.orders?.dining_tables?.table_number ?? "—",
    ...(scope.all ? [scope.names.get(x.branch_id) ?? "—"] : []),
    x.station ?? "—",
    x.status === "cancelled" && x.cancel_reason ? `cancelled: ${x.cancel_reason}` : x.status,
    items(x),
  ]);
  return (
    <ReportShell
      ctx={ctx}
      title="KOT details"
      basePath="/reports/kot-details"
      basis="kitchen tickets by the calendar date they were sent"
      landscape
      excel={rows.length > 0 ? { filename: `kot_details_${from}_${to}.csv`, header: head, rows: table } : null}
    >
      {error ? <Err e={{ message: "Could not read the kitchen tickets." }} /> : rows.length === 0 ? <Empty text="No kitchen ticket was sent in this period." /> : (
        <ReportTable head={head} textCols={head.map((_, i) => i)} zebra rows={table} />
      )}
      <Note>Shows the latest {LIMIT} tickets in the period. Choose a shorter range to see older ones.</Note>
    </ReportShell>
  );
}
