import { reportRpcError } from "@/lib/reports-pack";
import { minutesText, parseTurnaround } from "@/lib/reports-pack-4";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function TurnaroundReportPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Table turnaround time" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to } = ctx;

  const { data, error } = await supabase.rpc("report_table_turnaround", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseTurnaround(data as unknown);
  const t = rep?.totals;

  const csv: (string | number)[][] = [];
  if (rep) {
    for (const x of rep.byDay) csv.push(["Day", x.businessDate, x.bills, x.avgMinutes ?? "", ""]);
    for (const x of rep.byTable) csv.push(["Table", x.tableNumber, x.bills, x.avgMinutes ?? "", x.longestMinutes ?? ""]);
  }

  return (
    <ReportShell
      ctx={ctx}
      title="Table turnaround time"
      basePath="/reports/table-turnaround"
      basis="dine-in bills, from opening the bill to the last payment · by business day"
      excel={rep && csv.length > 0 ? { filename: `table_turnaround_${from}_${to}.csv`, header: ["Group", "Day / Table", "Bills", "Average minutes", "Longest minutes"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || !t || t.bills === 0 ? <Empty text="No paid dine-in bills in this period." /> : (
          <>
            <p className="text-sm">
              <b>{t.bills}</b> paid dine-in bill{t.bills === 1 ? "" : "s"}: a table stays occupied <b>{minutesText(t.avgMinutes)}</b> on average
              (half the tables are done within {minutesText(t.medianMinutes)}; the longest was {minutesText(t.longestMinutes)}).
            </p>

            <section>
              <h3 className="mb-2 text-sm font-bold">By day</h3>
              <ReportTable
                head={["Day", "Bills", "Average time"]}
                textCols={[0]}
                rows={rep.byDay.map((x) => [x.businessDate, String(x.bills), minutesText(x.avgMinutes)])}
              />
            </section>

            <section>
              <h3 className="mb-2 text-sm font-bold">By table</h3>
              <ReportTable
                head={["Table", "Bills", "Average time", "Longest"]}
                textCols={[0]}
                rows={rep.byTable.map((x) => [x.tableNumber, String(x.bills), minutesText(x.avgMinutes), minutesText(x.longestMinutes)])}
              />
            </section>

            <Note>
              Time runs from when the bill was opened to the last payment. Bills with no payment, voided or merged bills, and bills that took more than 24 hours are left out.
              A table left open and paid much later will pull its average up.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
