import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function CountVariancePage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Stock count variance", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_count_variance", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head = ["Day", "Item", "System said", "Counted", "Difference", "Cost each", "Value", "Note"];
  const cells = rows.map((x) => [s(x.day), s(x.item), q(x.expected, x.unit), q(x.counted, x.unit), q(x.diff, x.unit), money(n(x.unit_cost), c), money(n(x.value_diff), c), s(x.note, "—")]);
  return (
    <ReportShell
      ctx={ctx}
      title="Stock count variance"
      basePath="/reports/count-variance"
      basis="by count day · only items where the count differed"
      landscape
      excel={rows.length > 0 ? { filename: `count_variance_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No count differences in this period." /> : (
        <>
          <ReportTable head={head} textCols={[0, 1, 7]} rows={cells} total={["TOTAL", "", "", "", "", "", money(n(t.net), c), ""]} />
          <ReportTable head={["Extra found", "Missing", "Net"]} rows={[[money(n(t.gain), c), money(n(t.loss), c), money(n(t.net), c)]]} />
          <Note>Difference is counted less what the system said. A minus means stock is missing. Value is the difference times the cost on the day of the count.</Note>
        </>
      )}
    </ReportShell>
  );
}
