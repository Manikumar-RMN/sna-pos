import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const STATUS: Record<string, string> = { requested: "Waiting", part_issued: "Part issued", issued: "Issued", rejected: "Rejected", cancelled: "Cancelled" };

export default async function MrAuditPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Material request audit", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope } = ctx;
  const { data, error } = await supabase.rpc("report_mr_audit", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head = ["Day", "Request", ...(scope.all ? ["Outlet"] : []), "Department", "Asked by", "Status", "Decided by", "Decided on", "Hours taken", "Items", "Issue notes", "Reason"];
  const text = scope.all ? [0, 1, 2, 3, 4, 5, 6, 7, 10, 11] : [0, 1, 2, 3, 4, 5, 6, 9, 10];
  const cells = rows.map((x) => [
    s(x.day), s(x.number), ...(scope.all ? [s(x.outlet, "—")] : []), s(x.department), s(x.asked_by), STATUS[s(x.status)] ?? s(x.status),
    s(x.decided_by, "—"), s(x.decided_day, "—"), x.hours === null || x.hours === undefined ? "—" : `${n(x.hours)} h`,
    `${n(x.items_done)} of ${n(x.items)}`, s(x.issues, "—"), s(x.reason, "—"),
  ]);
  return (
    <ReportShell
      ctx={ctx}
      title="Material request audit"
      basePath="/reports/mr-audit"
      basis="by day the request was raised · who asked, who decided and how long it took"
      landscape
      excel={rows.length > 0 ? { filename: `mr_audit_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No stock requests in this period." /> : (
        <div className="space-y-4">
          <ReportTable
            head={["Requests", "Waiting", "Issued", "Rejected", "Cancelled", "Average hours to decide"]}
            rows={[[String(n(t.requests)), String(n(t.waiting)), String(n(t.issued)), String(n(t.rejected)), String(n(t.cancelled)), t.avg_hours === null || t.avg_hours === undefined ? "—" : `${n(t.avg_hours)} h`]]}
          />
          <ReportTable head={head} textCols={text} rows={cells} />
          <Note>Items shows how many of the requested items were issued in full. Hours taken is from the request to the first decision.</Note>
        </div>
      )}
    </ReportShell>
  );
}
