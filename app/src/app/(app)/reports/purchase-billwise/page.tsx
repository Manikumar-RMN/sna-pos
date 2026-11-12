import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/** Purchase bill-wise register: one line per supplier bill received, with the tax split into CGST / SGST / IGST. */
export default async function PurchaseBillwisePage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Purchase bill-wise register", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_purchase_billwise", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rows = err ? [] : asList(asObj(data).rows);

  const split = (x: Record<string, unknown>) => {
    const tax = n(x.tax);
    const intra = s(x.kind) === "intra";
    const inter = s(x.kind) === "inter";
    return { cgst: intra ? tax / 2 : 0, sgst: intra ? tax / 2 : 0, igst: inter ? tax : 0, unsplit: !intra && !inter ? tax : 0 };
  };
  const head = ["Receipt", "Received", "Supplier", "Supplier GSTIN", "Supplier bill", "Bill date", "Taxable value", "CGST", "SGST", "IGST", "Other charges", "Total", "Tax you can claim"];
  const line = (x: Record<string, unknown>) => {
    const t = split(x);
    return [s(x.number), s(x.date), s(x.supplier), s(x.gstin, "—"), s(x.bill_no, "—"), s(x.bill_date, "—"), money(n(x.taxable), c), money(t.cgst, c), money(t.sgst, c), money(t.igst, c), money(n(x.other_charges), c), money(n(x.total), c), money(n(x.claimable_tax), c)];
  };
  const sum = (f: (x: Record<string, unknown>) => number) => rows.reduce((a, x) => a + f(x), 0);
  const unsplit = sum((x) => split(x).unsplit);

  return (
    <ReportShell
      ctx={ctx}
      title="Purchase bill-wise register"
      basePath="/reports/purchase-billwise"
      basis="goods received · net of goods sent back · cancelled receipts left out"
      landscape
      excel={rows.length > 0 ? { filename: `purchase_billwise_${from}_${to}.csv`, header: head, rows: rows.map((x) => { const t = split(x); return [s(x.number), s(x.date), s(x.supplier), s(x.gstin), s(x.bill_no), s(x.bill_date), n(x.taxable), t.cgst, t.sgst, t.igst, n(x.other_charges), n(x.total), n(x.claimable_tax)]; }) } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No goods were received in this period." /> : (
        <>
          <ReportTable
            head={head}
            textCols={[0, 1, 2, 3, 4, 5]}
            zebra
            rows={rows.map(line)}
            total={[`TOTAL (${rows.length})`, "", "", "", "", "", money(sum((x) => n(x.taxable)), c), money(sum((x) => split(x).cgst), c), money(sum((x) => split(x).sgst), c), money(sum((x) => split(x).igst), c), money(sum((x) => n(x.other_charges)), c), money(sum((x) => n(x.total)), c), money(sum((x) => n(x.claimable_tax)), c)]}
          />
          <Note>
            A supplier in your state (the first two digits of the GSTIN) gives CGST and SGST in equal halves; a supplier in another state gives IGST.
            {unsplit > 0 ? ` ${money(unsplit, c)} of tax cannot be split because a supplier's GSTIN or your own GSTIN is missing.` : ""} Amounts are after goods sent back.
          </Note>
        </>
      )}
    </ReportShell>
  );
}
