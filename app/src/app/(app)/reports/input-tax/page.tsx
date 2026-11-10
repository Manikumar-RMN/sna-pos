import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const KIND: Record<string, string> = { intra: "Same state", inter: "Other state", unknown: "GSTIN missing" };

export default async function InputTaxPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Input tax (purchases)", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_input_tax", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head = ["Rate", "HSN", "Supplier", "Claimable", "Taxable value", "CGST", "SGST", "IGST", "Tax"];
  const cells = rows.map((x) => [`${n(x.rate)}%`, s(x.hsn, "—"), KIND[s(x.kind)] ?? s(x.kind), x.claimable === true ? "Yes" : "No", money(n(x.taxable), c), money(n(x.cgst), c), money(n(x.sgst), c), money(n(x.igst), c), money(n(x.tax), c)]);
  return (
    <ReportShell
      ctx={ctx}
      title="Input tax (purchases)"
      basePath="/reports/input-tax"
      basis="by receiving day · net of goods sent back · cancelled receipts are left out"
      landscape
      excel={rows.length > 0 ? { filename: `input_tax_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No tax was charged on goods received in this period." /> : (
        <>
          <ReportTable head={head} textCols={[0, 1, 2, 3]} rows={cells} total={["TOTAL", "", "", "", money(n(t.taxable), c), money(n(t.cgst), c), money(n(t.sgst), c), money(n(t.igst), c), money(n(t.tax), c)]} />
          <Note>
            Tax you can claim back: {money(n(t.claimable), c)}. A supplier in the same state as you (the first two digits of the GSTIN) gives CGST and SGST in equal halves; a supplier in another state gives IGST.
            {n(t.unsplit) > 0 ? ` ${money(n(t.unsplit), c)} of tax cannot be split because ${o.own_state ? "a supplier's GSTIN is missing" : "your own GSTIN is missing in Settings"}.` : ""}
            {n(o.typed_tax) > 0 ? ` A further ${money(n(o.typed_tax), c)} was typed as tax on the whole bill, not on a line, so it has no rate and is not listed above.` : ""}
            {" "}Tax is claimable only when the supplier has a GSTIN and Purchase rules allow claiming.
          </Note>
        </>
      )}
    </ReportShell>
  );
}
