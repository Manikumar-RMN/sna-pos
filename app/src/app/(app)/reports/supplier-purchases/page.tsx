import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function SupplierPurchasesPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Supplier-wise purchases", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_supplier_purchases", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head = ["Supplier", "Receipts", "Bought", "Returned", "Net", "Tax in bought", "Claim back", "Paid", "Still owed"];
  const cells = rows.map((x) => [s(x.supplier), String(n(x.receipts)), money(n(x.bought), c), money(n(x.returned), c), money(n(x.net), c), money(n(x.tax), c), money(n(x.claimable), c), money(n(x.paid), c), money(n(x.owed), c)]);
  return (
    <ReportShell
      ctx={ctx}
      title="Supplier-wise purchases"
      basePath="/reports/supplier-purchases"
      basis="by receiving day · cancelled receipts are left out"
      excel={rows.length > 0 ? { filename: `supplier_purchases_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No goods received in this period." /> : (
        <>
          <ReportTable head={head} rows={cells} total={["TOTAL", "", money(n(t.bought), c), money(n(t.returned), c), money(n(t.net), c), money(n(t.tax), c), money(n(t.claimable), c), money(n(t.paid), c), money(n(t.owed), c)]} />
          <Note>Bought is what the receipts came to before returns. Net is Bought less goods sent back. Tax in bought is the tax on those receipts; Claim back is the part you can claim from the tax office. Still owed is Net less what you have paid.</Note>
        </>
      )}
    </ReportShell>
  );
}
