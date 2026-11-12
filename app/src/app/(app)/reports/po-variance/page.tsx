import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s, q } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note, Notice } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function PoVariancePage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "PO rate variance", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_po_variance", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head = ["Day", "Receipt", "Order", ...(scope.all ? ["Outlet"] : []), "Supplier", "Item", "Quantity", "Ordered rate", "Paid rate", "Difference"];
  const text = scope.all ? [0, 1, 2, 3, 4, 5] : [0, 1, 2, 3, 4];
  const cells = rows.map((x) => [s(x.received_on), s(x.number), s(x.po_number), ...(scope.all ? [s(x.outlet, "—")] : []), s(x.supplier), s(x.item), q(x.qty, x.unit), money(n(x.ordered_rate), c), money(n(x.paid_rate), c), money(n(x.variance), c)]);
  return (
    <ReportShell
      ctx={ctx}
      title="PO rate variance"
      basePath="/reports/po-variance"
      basis="by receiving day · price paid before tax against the price on the purchase order"
      landscape
      excel={rows.length > 0 ? { filename: `po_variance_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No deliveries against purchase orders in this period." /> : (
        <>
          {o.truncated === true && <Notice>Only the newest {n(o.row_limit)} lines are listed. Choose a shorter period to see every line.</Notice>}
          <ReportTable groupBy={scope.all ? { col: head.indexOf("Outlet"), sums: { [head.length - 1]: rows.map((x) => n(x.variance)) }, format: (_, v) => money(v, c) } : undefined} head={head} textCols={text} rows={cells} total={["TOTAL", ...head.slice(1, -1).map(() => ""), money(n(t.variance), c)]} />
          <Note>
            Difference is quantity times (paid rate less ordered rate): a plus means you paid more than the order said. Paid more in total {money(n(t.over), c)}, paid less {money(Math.abs(n(t.under)), c)}.
          </Note>
        </>
      )}
    </ReportShell>
  );
}
