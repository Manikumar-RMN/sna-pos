import { money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

type Row = { session: string; bills: number; total: number; average: number; top_items: { item: string; qty: number }[] };

export default async function SessionSalesPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Session sales" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("session_report", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rows = err ? [] : ((data ?? []) as unknown as Row[]);
  const head = ["Session", "Bills", "Sales", "Average bill", "Top items"];
  const line = (x: Row) => [x.session, String(x.bills), money(Number(x.total), c), money(Number(x.average ?? 0), c), x.top_items.map((t) => `${t.item} (${t.qty})`).join(", ")];

  return (
    <ReportShell
      ctx={ctx}
      title="Session sales"
      basePath="/reports/session-sales"
      basis="finished bills by meal session (breakfast, lunch, dinner…)"
      landscape
      excel={rows.length > 0 ? { filename: `session_sales_${from}_${to}.csv`, header: head, rows: rows.map((x) => [x.session, x.bills, x.total, x.average, x.top_items.map((t) => `${t.item} (${t.qty})`).join(", ")]) } : null}
    >
      <div>
        {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No sales in this period." /> : (
          <>
            <ReportTable
              head={head}
              textCols={[0, 4]}
              rows={rows.map(line)}
              total={["TOTAL", String(rows.reduce((t, x) => t + Number(x.bills), 0)), money(rows.reduce((t, x) => t + Number(x.total), 0), c), "", ""]}
            />
            <Note>Sessions are set up in Settings. Bills made outside any session are shown as &quot;Other&quot;.</Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
