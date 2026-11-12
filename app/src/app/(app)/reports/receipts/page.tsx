import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note, Notice } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function ReceiptsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Receipts list", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_receipts", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head = ["Day", "Receipt", ...(scope.all ? ["Outlet"] : []), "Supplier", "Bill no", "Item", "Quantity", "Returned", "Rate", "Value", "Tax", "Claim back", "Status"];
  const text = scope.all ? [0, 1, 2, 3, 4, 5, 12] : [0, 1, 2, 3, 4, 11];
  const cells = rows.map((x) => [s(x.received_on), s(x.number), ...(scope.all ? [s(x.outlet, "—")] : []), s(x.supplier), s(x.supplier_bill_no, "—"), s(x.item), q(x.qty, x.unit), q(x.returned_qty, x.unit), money(n(x.unit_cost), c), money(n(x.line_total), c), n(x.tax_amount) > 0 ? `${money(n(x.tax_amount), c)} (${n(x.tax_rate)}%)` : "—", x.tax_claimable === true ? money(n(x.tax_amount), c) : "—", x.status === "cancelled" ? "Cancelled" : "Received"]);
  return (
    <ReportShell
      ctx={ctx}
      title="Receipts list"
      basePath="/reports/receipts"
      basis="by receiving day · every item received from suppliers"
      landscape
      excel={rows.length > 0 ? { filename: `receipts_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No goods received in this period." /> : (
        <>
          {o.truncated === true && <Notice>Only the newest {n(o.row_limit)} lines are listed. Choose a shorter period to see every line.</Notice>}
          <ReportTable head={head} textCols={text} rows={cells} groupBy={scope.all ? { col: 2, subtotal: (idx) => {
            const live = idx.map((i) => rows[i]).filter((x) => x.status !== "cancelled");
            return ["Outlet total", ...head.slice(1, -4).map(() => ""), money(live.reduce((a, x) => a + n(x.line_total), 0), c), "", "", `${new Set(live.map((x) => s(x.number))).size} receipts`];
          } } : undefined} total={["TOTAL", ...head.slice(1, -4).map(() => ""), money(n(t.value), c), "", "", `${n(t.receipts)} receipts`]} />
          <Note>Cancelled receipts are listed but not counted in the total. Rate is the price you paid per unit, as entered on the receipt. Tax is the line tax; Claim back shows it only where it can be claimed from the tax office (the supplier has a tax number and the restaurant claims input tax).</Note>
        </>
      )}
    </ReportShell>
  );
}
