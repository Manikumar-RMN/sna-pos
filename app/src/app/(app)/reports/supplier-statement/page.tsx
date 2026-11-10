import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function SupplierStatementPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; supplier?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Supplier statement", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data: sups } = await supabase.from("suppliers").select("id, name").order("name");
  const supplier = sp.supplier && (sups ?? []).some((x) => x.id === sp.supplier) ? sp.supplier : null;
  let o: ReturnType<typeof asObj> | null = null;
  let err = null;
  if (supplier) {
    const { data, error } = await supabase.rpc("report_supplier_statement", { p_supplier: supplier, p_from: from, p_to: to });
    err = reportRpcError(error);
    o = err ? null : asObj(data);
  }
  const rows = o ? asList(o.rows) : [];
  const head = ["Date", "Entry", "Reference", "Bill / refund", "Paid / returned", "Balance owed"];
  const cells = rows.map((x) => [s(x.day), s(x.kind), s(x.ref), n(x.debit) > 0 ? money(n(x.debit), c) : "", n(x.credit) > 0 ? money(n(x.credit), c) : "", money(n(x.balance), c)]);
  const sup = o ? asObj(o.supplier) : null;
  return (
    <ReportShell
      ctx={ctx}
      title="Supplier statement"
      basePath="/reports/supplier-statement"
      basis="by entry day · bills, goods returned, payments and refunds"
      excel={o && rows.length > 0 ? { filename: `supplier_statement_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      <form method="get" className="no-print mb-3 flex flex-wrap items-end gap-2 text-sm">
        <input type="hidden" name="from" value={from} />
        <input type="hidden" name="to" value={to} />
        <label className="block">
          <span className="mb-1 block text-xs font-semibold">Supplier</span>
          <select name="supplier" defaultValue={supplier ?? ""} className="field h-10 text-sm">
            <option value="">Choose a supplier…</option>
            {(sups ?? []).map((x) => (
              <option key={x.id} value={x.id}>
                {x.name}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="btn btn-primary px-4 text-sm">
          Show
        </button>
      </form>
      {!supplier ? <Empty text="Choose a supplier to see their statement." /> : err ? <Err e={err} /> : !o ? null : (
        <div className="space-y-3">
          <p className="text-sm">
            <b>{s(sup?.name)}</b>
            {sup?.tax_no ? ` · GSTIN ${s(sup.tax_no)}` : ""}
            {sup?.phone ? ` · ${s(sup.phone)}` : ""} · {n(sup?.payment_days)} credit days
          </p>
          <ReportTable
            head={head}
            textCols={[0, 1, 2]}
            rows={[["", "Opening balance", "", "", "", money(n(o.opening), c)], ...cells]}
            total={["", "CLOSING BALANCE", "", "", "", money(n(o.closing), c)]}
          />
          <Note>Balance owed is what you owe the supplier after each entry; a minus figure means they owe you (paid for goods you sent back). Opening balance is everything before the first date. The dates above apply; pick the Supplier, then Display.</Note>
        </div>
      )}
    </ReportShell>
  );
}
