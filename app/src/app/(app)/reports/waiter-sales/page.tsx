import { parseWaiters, reportRpcError } from "@/lib/reports-pack";
import { money } from "@/lib/format";
import { CsvButton } from "../csv-button";
import { Card, Empty, Err, Note, Table } from "../_components/ui";
import { loadReport, ReportShell } from "../_components/report-context";

export default async function WaiterSalesPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Waiter-wise sales" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  // Sales per staff member per outlet come from the database (finished bills, not merged, not complimentary), which
  // follows the outlet picker itself. The same person can have a row for each outlet.
  const { data, error } = await supabase.rpc("report_waiter_sales", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const waiters = err ? [] : parseWaiters(data as unknown);
  const totalCovers = waiters.reduce((s, w) => s + w.covers, 0);
  const totalBills = waiters.reduce((s, w) => s + w.bills, 0);
  const totalSales = waiters.reduce((s, w) => s + w.total, 0);

  const head = scope.all ? ["Staff", "Outlet", "Bills", "Covers", "Sales", "Average bill"] : ["Staff", "Bills", "Covers", "Sales", "Average bill"];
  const line = (w: (typeof waiters)[number]) => {
    const nums = [w.bills, w.covers, w.total, w.average] as const;
    return scope.all ? [w.name, w.outlet_name, ...nums] : [w.name, ...nums];
  };

  return (
    <ReportShell ctx={ctx} title="Waiter-wise sales" basePath="/reports/waiter-sales">
      <Card
        title="Sales by staff"
        action={
          waiters.length > 0 ? (
            <CsvButton filename={`waiters_${from}_${to}.csv`} header={head} rows={waiters.map(line)} />
          ) : null
        }
      >
        {err ? <Err e={err} /> : waiters.length === 0 ? <Empty text="No sales in this period." /> : (
          <>
            <Table
              head={head}
              textCols={scope.all ? [0, 1] : [0]}
              rows={waiters.map((w) => {
                const cells = line(w).map(String);
                const i = scope.all ? 2 : 1;
                return [
                  ...cells.slice(0, i),
                  String(w.bills),
                  w.covers > 0 ? String(w.covers) : "—",
                  money(w.total, c),
                  money(w.average, c),
                ];
              })}
            />
            <p className="mt-2 text-sm font-semibold">
              {totalBills} bill{totalBills === 1 ? "" : "s"}, {money(totalSales, c)} in total{scope.all ? " (all outlets)" : ""}.
            </p>
            <Note>
              The waiter is shown where one was recorded; otherwise the cashier who took the bill (counter and takeaway bills). Complimentary and staff-meal bills are not included.
              {totalCovers === 0 ? " Covers were not entered on these bills." : ""}
              {scope.all ? " A person who worked in more than one outlet has a row for each outlet." : ""}
            </Note>
          </>
        )}
      </Card>
    </ReportShell>
  );
}
