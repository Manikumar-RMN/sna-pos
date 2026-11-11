import { money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/** Table wise sales (Winsar "Table Wise Sales"): bills, covers and sales for each table. */
type Row = { table: string; bills: number; covers: number; amount: number };

export default async function TableSalesPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Table wise sales" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_table_sales", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rows = err ? [] : ((data ?? []) as unknown as Row[]);
  const head = ["Table", "Bills", "Covers", "Sales", "Average per bill"];
  const avg = (x: Row) => (Number(x.bills) > 0 ? Number(x.amount) / Number(x.bills) : 0);
  return (
    <ReportShell
      ctx={ctx}
      title="Table wise sales"
      basePath="/reports/table-sales"
      basis="completed bills by business day · bill totals with tax"
      excel={rows.length > 0 ? { filename: `table_sales_${from}_${to}.csv`, header: head, rows: rows.map((x) => [x.table, Number(x.bills), Number(x.covers), Number(x.amount), Number(avg(x).toFixed(2))]) } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No bills in this period." /> : (
        <ReportTable head={head} textCols={[0]} zebra rows={rows.map((x) => [x.table, String(Number(x.bills)), String(Number(x.covers)), money(Number(x.amount), c), money(avg(x), c)])}
          total={["TOTAL", String(rows.reduce((t, x) => t + Number(x.bills), 0)), String(rows.reduce((t, x) => t + Number(x.covers), 0)), money(rows.reduce((t, x) => t + Number(x.amount), 0), c), ""]} />
      )}
      <Note>Takeaway, delivery and counter bills have no table and are listed under "No table".</Note>
    </ReportShell>
  );
}
