import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function ProductionReportPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Production summary", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, scope, user } = ctx;
  // A batch is dated by the calendar day it was made. When the trading day is still open past midnight, "today" is
  // yesterday's date, so stretch the end of the range to the calendar day so a batch made after midnight still shows.
  const to = ctx.to === ctx.today && ctx.calendarToday > ctx.to ? ctx.calendarToday : ctx.to;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_production", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const byItem = asList(o.by_item);
  const used = asList(o.used);
  const waiting = asList(o.waiting);
  const t = asObj(o.totals);
  const head = ["Day", "Batch", ...(scope.all ? ["Outlet"] : []), "Item", "Quantity", "Cost per unit", "Cost"];
  const text = scope.all ? [0, 1, 2, 3] : [0, 1, 2];
  const cells = rows.map((x) => [s(x.produced_on), s(x.number), ...(scope.all ? [s(x.outlet, "—")] : []), s(x.item), q(x.qty, x.unit), money(n(x.unit_cost), c), money(n(x.value), c)]);
  return (
    <ReportShell
      ctx={ctx}
      title="Production summary"
      basePath="/reports/production"
      basis="by day the batch was made · prepared items made from ingredients"
      excel={rows.length > 0 ? { filename: `production_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 && waiting.length === 0 ? <Empty text="Nothing was made in this period." /> : (
        <div className="space-y-6">
          {rows.length > 0 && (
            <>
              <section>
                <h3 className="mb-2 text-sm font-bold">By item</h3>
                <ReportTable
                  head={["Item", "Batches", "Quantity", "Average cost per unit", "Cost"]}
                  textCols={[0]}
                  rows={byItem.map((x) => [s(x.item), String(n(x.runs)), q(x.qty, x.unit), money(n(x.avg_cost), c), money(n(x.value), c)])}
                  total={["TOTAL", String(n(t.runs)), "", "", money(n(t.value), c)]}
                />
              </section>
              <section>
                <h3 className="mb-2 text-sm font-bold">Ingredients used</h3>
                <ReportTable head={["Ingredient", "Quantity", "Cost"]} textCols={[0]} rows={used.map((x) => [s(x.ingredient), q(x.qty, x.unit), money(n(x.value), c)])} />
              </section>
              <section>
                <h3 className="mb-2 text-sm font-bold">Every batch</h3>
                <ReportTable head={head} textCols={text} rows={cells} />
              </section>
            </>
          )}
          {waiting.length > 0 && (
            <section>
              <h3 className="mb-2 text-sm font-bold">Planned, not made yet</h3>
              <ReportTable head={["For day", "Plan", ...(scope.all ? ["Outlet"] : []), "Item", "Quantity"]} textCols={scope.all ? [0, 1, 2, 3] : [0, 1, 2]} rows={waiting.map((x) => [s(x.planned_for), s(x.number), ...(scope.all ? [s(x.outlet, "—")] : []), s(x.item), q(x.qty, x.unit)])} />
            </section>
          )}
          <Note>The cost of a batch is the ingredients at the cost they held when the batch was made. The prepared item is then on the shelf at that cost, and shows in Stock on hand and Stock ledger.</Note>
        </div>
      )}
    </ReportShell>
  );
}
