import { orderTypeLabel, dateTime } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { ageText, csvWithFooter, parsePendingKot } from "@/lib/reports-pack-2";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function PendingKotPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Pending KOT" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;

  // Kitchen tickets with food still waiting (new or preparing) on live bills. The database follows the outlet picker.
  const { data, error } = await supabase.rpc("report_pending_kot", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const { rows, kots, items } = err ? { rows: [], kots: 0, items: 0 } : parsePendingKot(data as unknown);

  const itemsText = (k: (typeof rows)[number]) =>
    k.items.map((i) => `${i.quantity} × ${i.name}${i.note ? ` (${i.note})` : ""} [${i.status}]`).join("; ");
  const head = ["KOT", "Time", "Waiting", "Bill", "Table", "Type", "Station", "Items", ...(scope.all ? ["Outlet"] : [])];
  const cells = (k: (typeof rows)[number]) => [
    k.ticketNumber || "—",
    dateTime(k.kotTime, user.timezone),
    ageText(k.minutesPending),
    k.billNumber || "—",
    k.table ?? "—",
    orderTypeLabel[k.orderType] ?? (k.orderType || "—"),
    k.station || "—",
    itemsText(k) || "—",
    ...(scope.all ? [k.outletName] : []),
  ];
  const textCols = head.map((_, i) => i);

  return (
    <ReportShell
      ctx={ctx}
      title="Pending KOT"
      basePath="/reports/pending-kot"
      basis="kitchen tickets with food still waiting · bills of the chosen days"
      landscape
      excel={rows.length > 0 ? { filename: `pending_kot_${from}_${to}.csv`, header: head, rows: csvWithFooter(head.length, rows.map(cells), ["TOTAL", `${kots} KOT`, "", "", "", "", "", `${items} item lines`], null) } : null}
    >
      <div>
        {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No kitchen tickets are waiting for this period." /> : (
          <>
            <ReportTable
              head={head}
              textCols={textCols}
              rows={rows.map(cells)}
              total={["TOTAL", `${kots} KOT`, "", "", "", "", "", `${items} item lines`, ...(scope.all ? [""] : [])]}
            />
            <Note>
              Oldest ticket first. Only the lines still waiting are listed (new or preparing); cancelled lines and finished bills are left out. The days chosen apply to the bill&apos;s business day, so an older bill that is still open shows when its day is in the range.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
