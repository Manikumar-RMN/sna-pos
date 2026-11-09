import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const LABEL: Record<string, string> = { requested: "Waiting", part_issued: "Part issued", issued: "Issued", rejected: "Turned down", cancelled: "Withdrawn", pending: "Waiting for approval", approved: "Approved", ordered: "Ordered" };

export default async function RequestsReportPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Request and requisition status", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_requests", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const reqs = err ? [] : asList(o.stock_requests);
  const prs = err ? [] : asList(o.requisitions);
  const reqHead = ["Day", "Request", "Department", "Status", "Item", "Requested", "Issued", "Balance"];
  const reqCells = reqs.map((x) => [s(x.day), s(x.number), s(x.department), LABEL[s(x.status)] ?? s(x.status), s(x.item), q(x.requested, x.unit), q(x.issued, x.unit), q(x.balance, x.unit)]);
  const prHead = ["Day", "Requisition", "Status", "Estimated", "Order", "Reason"];
  const prCells = prs.map((x) => [s(x.day), s(x.number), LABEL[s(x.status)] ?? s(x.status), money(n(x.est_total), c), s(x.order_number, "—"), s(x.reason, "—")]);
  return (
    <ReportShell
      ctx={ctx}
      title="Request and requisition status"
      basePath="/reports/requests"
      basis="by the day each was made"
      landscape
      excel={reqCells.length + prCells.length > 0 ? { filename: `requests_${from}_${to}.csv`, header: ["Part", ...reqHead], rows: [...reqCells.map((x) => ["Stock request", ...x]), ...prCells.map((x) => ["Requisition", x[0], x[1], "", x[2], x[3], x[4], x[5], ""])] } : null}
    >
      {err ? <Err e={err} /> : reqCells.length + prCells.length === 0 ? <Empty text="No requests or requisitions in this period." /> : (
        <div className="space-y-6">
          <section>
            <h3 className="mb-2 text-sm font-bold">Stock requests (what is still to be issued)</h3>
            {reqCells.length === 0 ? <Empty text="None in this period." /> : <ReportTable head={reqHead} textCols={[0, 1, 2, 3, 4]} rows={reqCells} />}
          </section>
          <section>
            <h3 className="mb-2 text-sm font-bold">Purchase requisitions</h3>
            {prCells.length === 0 ? <Empty text="None in this period." /> : <ReportTable head={prHead} textCols={[0, 1, 2, 4, 5]} rows={prCells} />}
          </section>
          <Note>Balance is what was asked for and not yet issued. A requisition becomes an order once it is approved and a supplier is chosen.</Note>
        </div>
      )}
    </ReportShell>
  );
}
