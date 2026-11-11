import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function FifoValuationPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Stock value: FIFO and average", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_fifo_valuation", {});
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const multi = new Set(rows.map((x) => s(x.outlet))).size > 1;
  const head = [...(multi ? ["Outlet"] : []), "Ingredient", "Group", "On hand", "Average cost", "Value at average", "Value at FIFO", "Difference"];
  const cells = rows.map((x) => [
    ...(multi ? [s(x.outlet)] : []),
    s(x.item),
    s(x.category, "—"),
    q(x.on_hand, s(x.unit)),
    money(n(x.avg_cost), c),
    money(n(x.avg_value), c),
    money(n(x.fifo_value), c),
    money(n(x.diff), c),
  ]);
  const textCols = multi ? [0, 1, 2] : [0, 1];
  return (
    <ReportShell
      ctx={ctx}
      title="Stock value: FIFO and average"
      basePath="/reports/fifo-valuation"
      basis="right now · what is on hand, valued two ways"
      excel={rows.length > 0 ? { filename: "stock_value_fifo_vs_average.csv", header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="There is no stock on hand." /> : (
        <>
          <ReportTable
            head={head}
            textCols={textCols}
            rows={cells}
            total={head.map((_, i) => (i === 0 ? "TOTAL" : i === head.length - 3 ? money(n(t.avg_value), c) : i === head.length - 2 ? money(n(t.fifo_value), c) : i === head.length - 1 ? money(n(t.diff), c) : ""))}
          />
          <Note>
            Value at average is what SNA POS uses for costing, the stock value on your reports and the cost of goods sold. Value at FIFO is shown for comparison only: it assumes the oldest stock is used first, so what is left on the shelf is valued at the newest purchase rates (goods sent back are left out). Any stock not covered by a purchase (opening stock or count gains) is valued at the average cost in both columns. A positive difference means prices have been rising. If your accountant asks for FIFO, this is the figure to give them; the books are not changed by it.
          </Note>
        </>
      )}
    </ReportShell>
  );
}
