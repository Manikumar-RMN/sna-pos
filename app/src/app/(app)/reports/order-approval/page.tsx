import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/**
 * Order approval report (Winsar "Order Approval Report"). Every table order a guest sends from the QR code waits for the
 * staff to accept or reject it; this lists them with who decided, when, how long the guest waited, and the reason given for
 * a rejection. Read straight from public.qr_orders, nothing is worked out again.
 */
type Row = {
  id: string;
  status: "pending" | "accepted" | "rejected";
  estimated_total: number | null;
  guest_name: string | null;
  reject_reason: string | null;
  created_at: string;
  decided_at: string | null;
  items: unknown;
  dining_tables: { table_number: string } | null;
  users: { full_name: string | null } | null;
};

const itemCount = (items: unknown): number =>
  Array.isArray(items) ? items.reduce((t, x) => t + Number((x as { qty?: number; quantity?: number })?.qty ?? (x as { quantity?: number })?.quantity ?? 1), 0) : 0;

export default async function OrderApprovalPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Order approval", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase
    .from("qr_orders")
    .select("id, status, estimated_total, guest_name, reject_reason, created_at, decided_at, items, dining_tables(table_number), users!qr_orders_decided_by_fkey(full_name)")
    .gte("created_at", `${from}T00:00:00`)
    .lte("created_at", `${to}T23:59:59.999`)
    .order("created_at", { ascending: false })
    .limit(500);
  const rows = (error ? [] : (data ?? [])) as unknown as Row[];

  const waited = (r: Row) => (r.decided_at ? Math.max(0, Math.round((Date.parse(r.decided_at) - Date.parse(r.created_at)) / 60000)) : null);
  const label = { pending: "Waiting", accepted: "Accepted", rejected: "Rejected" } as const;
  const count = (s: Row["status"]) => rows.filter((x) => x.status === s).length;
  const sum = (s: Row["status"]) => rows.filter((x) => x.status === s).reduce((t, x) => t + Number(x.estimated_total ?? 0), 0);

  const table = rows.map((x) => [
    new Date(x.created_at).toLocaleString(),
    x.dining_tables?.table_number ?? "—",
    x.guest_name ?? "—",
    String(itemCount(x.items)),
    money(Number(x.estimated_total ?? 0), c),
    label[x.status],
    x.users?.full_name ?? "—",
    waited(x) === null ? "—" : `${waited(x)} min`,
    x.reject_reason ?? "",
  ]);
  const head = ["Sent", "Table", "Guest", "Items", "Estimate", "Result", "Decided by", "Waited", "Reason"];

  return (
    <ReportShell
      ctx={ctx}
      title="Order approval"
      basePath="/reports/order-approval"
      basis="table orders sent from the QR code · by the day the guest sent them"
      excel={rows.length > 0 ? { filename: `order_approval_${from}_${to}.csv`, header: head, rows: table } : null}
    >
      {error ? (
        <Err e={{ message: "Could not read the table orders." }} />
      ) : rows.length === 0 ? (
        <Empty text="No table order was sent from a QR code in this period." />
      ) : (
        <div className="space-y-4">
          <ReportTable
            head={["Result", "Orders", "Estimated value"]}
            textCols={[0]}
            rows={[
              ["Accepted", String(count("accepted")), money(sum("accepted"), c)],
              ["Rejected", String(count("rejected")), money(sum("rejected"), c)],
              ["Still waiting", String(count("pending")), money(sum("pending"), c)],
            ]}
          />
          <ReportTable head={head} textCols={[0, 1, 2, 5, 6, 8]} zebra rows={table} />
          <Note>The estimate is what the guest saw when ordering; the bill is worked out again when staff accept the order. Shows the latest 500 in the period.</Note>
        </div>
      )}
    </ReportShell>
  );
}
