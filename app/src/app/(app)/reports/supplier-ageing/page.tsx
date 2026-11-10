import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function SupplierAgeingPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Supplier ageing", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_supplier_ageing", { p_asof: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head = ["Supplier", "Not yet due", "1–30 days late", "31–60", "61–90", "Over 90", "Total owed", "Paid in advance"];
  const cells = rows.map((x) => [s(x.supplier), money(n(x.not_due), c), money(n(x.d30), c), money(n(x.d60), c), money(n(x.d90), c), money(n(x.d90p), c), money(n(x.owed), c), n(x.advance) > 0 ? money(n(x.advance), c) : "—"]);
  return (
    <ReportShell
      ctx={ctx}
      title="Supplier ageing"
      basePath="/reports/supplier-ageing"
      basis={`as at ${to} · what you still owe, by how late it is`}
      landscape
      excel={rows.length > 0 ? { filename: `supplier_ageing_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="Nothing is owed to any supplier." /> : (
        <>
          <ReportTable head={head} rows={cells} total={["TOTAL", money(n(t.not_due), c), money(n(t.d30), c), money(n(t.d60), c), money(n(t.d90), c), money(n(t.d90p), c), money(n(t.owed), c), money(n(t.advance), c)]} />
          <Note>Late is counted from the due date on each receipt (the supplier&apos;s credit days after the bill date). Paid in advance is money the supplier is holding for you: advances you have paid and not yet used, plus anything paid for goods you then sent back. Use it against a bill from Purchases → Advances, or ask for a refund. The date at the top right sets &ldquo;as at&rdquo;.</Note>
        </>
      )}
    </ReportShell>
  );
}
