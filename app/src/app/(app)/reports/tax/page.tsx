import { money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { csvWithFooter, parseTax, taxTotalsDiffer } from "@/lib/reports-pack-2";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function TaxReportPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Tax report", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_tax", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const t = err ? null : parseTax(data as unknown);

  const head = ["Tax", "Rate", "Taxable amount", "Tax"];
  const rate = (n: number) => `${Number.isInteger(n) ? n : n.toFixed(2).replace(/0$/, "")}%`;

  return (
    <ReportShell
      ctx={ctx}
      title="Tax report"
      basePath="/reports/tax"
      basis="finished bills · by business day · complimentary bills included"
      excel={t && t.rows.length > 0 ? { filename: `tax_${from}_${to}.csv`, header: head, rows: csvWithFooter(head.length, t.rows.map((x) => [x.component, x.rate, x.taxable, x.tax]), ["TOTAL", "", t.totals.taxable, t.totals.tax], null) } : null}
    >
      <div>
        {err || !t ? <Err e={err ?? { message: "Could not load the report." }} /> : t.rows.length === 0 ? <Empty text="No tax was charged in this period." /> : (
          <>
            <ReportTable
              head={head}
              textCols={[0]}
              rows={t.rows.map((x) => [x.component, rate(x.rate), money(x.taxable, c), money(x.tax, c)])}
              total={["TOTAL", "", money(t.totals.taxable, c), money(t.totals.tax, c)]}
            />
            {t.credit.count > 0 && (
              <section className="mt-6">
                <h2 className="mb-2 text-sm font-bold">Less: credit notes issued in this period</h2>
                <ReportTable
                  head={head}
                  textCols={[0]}
                  rows={t.creditRows.map((x) => [x.component, rate(x.rate), `-${money(x.taxable, c)}`, `-${money(x.tax, c)}`])}
                  total={[`CREDIT NOTES (${t.credit.count})`, "", "", `-${money(t.credit.tax, c)}`]}
                />
                <div className="card mt-3 max-w-xs p-3">
                  <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>Net tax (bills less credit notes)</div>
                  <div className="text-lg font-bold tabular-nums">{money(t.totals.tax - t.credit.tax, c)}</div>
                </div>
                <Note>A credit note counts in the day it is issued. Its tax is reversed at the rates of the original bill.</Note>
              </section>
            )}
            {scope.all && t.byOutlet.length > 0 && (
              <section className="mt-6">
                <h2 className="mb-2 text-sm font-bold">By outlet</h2>
                <ReportTable
                  head={["Outlet", "Tax", "Rate", "Taxable amount", "Tax"]}
                  textCols={[0, 1]}
                  rows={t.byOutlet.map((x) => [x.outletName, x.component, rate(x.rate), money(x.taxable, c), money(x.tax, c)])}
                  total={["TOTAL", "", "", money(t.totals.taxable, c), money(t.totals.tax, c)]}
                />
                <Note>Each outlet is listed with its own tax lines, so tax can be filed per outlet.</Note>
              </section>
            )}
            <div className="mt-4 grid max-w-xl grid-cols-1 gap-3 sm:grid-cols-2">
              <div className="card p-3">
                <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>Tax by rate (total of the lines above)</div>
                <div className="text-lg font-bold tabular-nums">{money(t.totals.tax, c)}</div>
              </div>
              <div className="card p-3">
                <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>Tax on the bills (bill totals)</div>
                <div className="text-lg font-bold tabular-nums">{money(t.totals.ordersTaxTotal, c)}</div>
              </div>
            </div>
            {taxTotalsDiffer(t.totals) && (
              <Note>
                The two totals differ by {money(Math.abs(t.totals.tax - t.totals.ordersTaxTotal), c)}. The first adds up each tax line; the second adds the tax printed on each bill. A small gap usually comes from rounding or from tax that is already included in the price. Ask your accountant which one to file.
              </Note>
            )}
            {(t.totals.taxIncluded > 0 || t.totals.exemptSales > 0) && (
              <Note>
                {t.totals.taxIncluded > 0 ? `Tax included in prices: ${money(t.totals.taxIncluded, c)}. ` : ""}
                {t.totals.exemptSales > 0 ? `Tax-exempt sales: ${money(t.totals.exemptSales, c)}.` : ""}
              </Note>
            )}
          </>
        )}
      </div>
    </ReportShell>
  );
}
