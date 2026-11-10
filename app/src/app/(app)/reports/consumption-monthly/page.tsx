import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const monthLabel = (m: string) => `${MONTHS[Number(m.slice(5, 7)) - 1] ?? m.slice(5, 7)} ${m.slice(0, 4)}`;

export default async function ConsumptionMonthlyPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Item consumption monthwise", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_consumption_monthly", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const months: string[] = err || !Array.isArray(o.months) ? [] : (o.months as unknown[]).filter((m): m is string => typeof m === "string");
  const rows = err ? [] : asList(o.rows);
  const mv = asList(o.month_values);
  const t = asObj(o.totals);
  const head = ["Item", ...months.map(monthLabel), "Total used", "Value"];
  const cells = rows.map((x) => {
    const bm = asObj(x.by_month);
    return [s(x.item), ...months.map((m) => (bm[m] === undefined ? "—" : q(bm[m], s(x.unit)))), q(x.qty, s(x.unit)), money(n(x.value), c)];
  });
  const totalRow = ["TOTAL", ...months.map((m) => money(n(mv.find((x) => s(x.month) === m)?.value), c)), "", money(n(t.value), c)];
  return (
    <ReportShell
      ctx={ctx}
      title="Item consumption monthwise"
      basePath="/reports/consumption-monthly"
      basis="by business day · sold in dishes, wasted, sent to another outlet, issued or used in a batch"
      landscape
      excel={rows.length > 0 ? { filename: `consumption_monthwise_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No stock went out in this period." /> : (
        <>
          <ReportTable head={head} textCols={[0]} rows={cells} total={totalRow} />
          <Note>Quantity is shown for each month; the last row adds up the value of what went out in each month. Biggest value first.</Note>
        </>
      )}
    </ReportShell>
  );
}
