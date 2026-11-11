import { money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/** Product group sales (Winsar "Outlet Product Group Sales"): what each menu group sold in the period. */
type Row = { group: string; units: number; amount: number; discount: number };

export default async function GroupSalesPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Product group sales" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_group_sales", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rows = err ? [] : ((data ?? []) as unknown as Row[]);
  const total = rows.reduce((t, x) => t + Number(x.amount), 0);
  const head = ["Product group", "Units", "Sales", "Discount", "Share"];
  const table = rows.map((x) => [x.group, String(Number(x.units)), money(Number(x.amount), c), money(Number(x.discount), c), total > 0 ? `${((Number(x.amount) / total) * 100).toFixed(1)}%` : "—"]);
  return (
    <ReportShell
      ctx={ctx}
      title="Product group sales"
      basePath="/reports/group-sales"
      basis="completed bills by business day · before tax, cancelled items left out"
      excel={rows.length > 0 ? { filename: `group_sales_${from}_${to}.csv`, header: head, rows: rows.map((x) => [x.group, Number(x.units), Number(x.amount), Number(x.discount), total > 0 ? Number(((Number(x.amount) / total) * 100).toFixed(1)) : 0]) } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No sales in this period." /> : (
        <ReportTable head={head} textCols={[0]} zebra rows={table} total={["TOTAL", String(rows.reduce((t, x) => t + Number(x.units), 0)), money(total, c), money(rows.reduce((t, x) => t + Number(x.discount), 0), c), ""]} />
      )}
      <Note>Sales are before tax and service charge. A dish with no menu group is counted under "No group".</Note>
    </ReportShell>
  );
}
