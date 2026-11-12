import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

type Line = { item: string; hsn: string; uqc: string; qty: number; rate: number; taxable: number; cgst: number; sgst: number; igst: number };
type Bill = {
  outlet: string; date: string; number: string; session: string; comp: boolean; buyerName: string; gstin: string;
  gross: number; discount: number; service: number; tax: number; rounding: number; total: number;
  taxable: number; cgst: number; sgst: number; igst: number; lines: Line[];
};

const other = (b: Bill) => Math.round((b.tax - b.cgst - b.sgst - b.igst) * 100) / 100;
const sum = (list: Bill[], f: (b: Bill) => number) => list.reduce((a, b) => a + f(b), 0);

/**
 * Sales bill-wise register (as Winsar's "Sales Billwise Summary / Details"): one line per finished bill with the customer GSTIN,
 * taxable value and tax split; tick "Show item lines" to see every item with its HSN / SAC, rate and tax. Grouped by outlet with
 * outlet totals when several outlets are in view, and ending with a grand total.
 */
export default async function SalesBillwisePage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; details?: string }> }) {
  const sp = await searchParams;
  const details = sp.details === "1";
  const r = await loadReport(sp, { title: "Sales bill-wise register", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  const m = (x: number) => money(x, c);
  const { data, error } = await supabase.rpc("report_sales_billwise", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const body: Record<string, unknown> = err ? {} : asObj(data);
  const bills: Bill[] = err ? [] : asList(body.rows).map((x) => ({
    outlet: s(x.outlet_name, "Unknown outlet"), date: s(x.business_date), number: s(x.bill_number), session: s(x.session, "Other"),
    comp: x.comp_kind != null && x.comp_kind !== "", buyerName: s(x.buyer_name, ""), gstin: s(x.buyer_gstin, ""),
    gross: n(x.gross), discount: n(x.discount), service: n(x.service_charge), tax: n(x.tax), rounding: n(x.rounding), total: n(x.grand_total),
    taxable: n(x.taxable), cgst: n(x.cgst), sgst: n(x.sgst), igst: n(x.igst),
    lines: asList(x.lines).map((l): Line => ({ item: s(l.item), hsn: s(l.hsn, ""), uqc: s(l.uqc, ""), qty: n(l.qty), rate: n(l.rate), taxable: n(l.taxable), cgst: n(l.cgst), sgst: n(l.sgst), igst: n(l.igst) })),
  }));
  const truncated = body.truncated === true;
  const hasIgst = bills.some((b) => b.igst);
  const hasOther = bills.some((b) => Math.abs(other(b)) > 0.005);

  const toggles = [{ name: "details", label: "Show item lines (HSN / SAC, rate, tax)", checked: details }];
  const groups = scope.all ? [...new Set(bills.map((b) => b.outlet))].map((name) => ({ name, list: bills.filter((b) => b.outlet === name) })) : [{ name: "", list: bills }];

  // Summary columns
  const head = ["Date", "Session", "Bill", "Customer", "GSTIN", "Taxable value", "Discount", "Service", "CGST", "SGST", ...(hasIgst ? ["IGST"] : []), ...(hasOther ? ["Other tax"] : []), "Round off", "Bill amount"];
  const textCols = [0, 1, 2, 3, 4];
  const cells = (b: Bill) => [b.date, b.session, b.comp ? `${b.number} · complimentary` : b.number, b.buyerName || "—", b.gstin || "—", m(b.taxable), m(b.discount), m(b.service), m(b.cgst), m(b.sgst), ...(hasIgst ? [m(b.igst)] : []), ...(hasOther ? [m(other(b))] : []), m(b.rounding), m(b.total)];
  const totals = (label: string, list: Bill[]) => [label, "", "", "", "", m(sum(list, (b) => b.taxable)), m(sum(list, (b) => b.discount)), m(sum(list, (b) => b.service)), m(sum(list, (b) => b.cgst)), m(sum(list, (b) => b.sgst)), ...(hasIgst ? [m(sum(list, (b) => b.igst))] : []), ...(hasOther ? [m(sum(list, other))] : []), m(sum(list, (b) => b.rounding)), m(sum(list, (b) => b.total))];

  // By tax rate (from the item lines)
  const rates = [...new Set(bills.flatMap((b) => b.lines.map((l) => l.rate)))].sort((a, b) => a - b);
  const byRate = rates.map((rt) => {
    const ls = bills.flatMap((b) => b.lines.filter((l) => l.rate === rt));
    const t = (f: (l: Line) => number) => ls.reduce((a, l) => a + f(l), 0);
    return [`${rt}%`, m(t((l) => l.taxable)), m(t((l) => l.cgst)), m(t((l) => l.sgst)), m(t((l) => l.igst)), m(t((l) => l.cgst + l.sgst + l.igst))];
  });

  // Excel: one row per bill (summary) or per item line (details)
  const csvHead = details
    ? ["Outlet", "Date", "Session", "Bill", "Customer", "GSTIN", "Item", "HSN / SAC", "Unit", "Qty", "Rate %", "Taxable value", "CGST", "SGST", "IGST"]
    : ["Outlet", "Date", "Session", "Bill", "Customer", "GSTIN", "Taxable value", "Discount", "Service", "CGST", "SGST", "IGST", "Other tax", "Round off", "Bill amount"];
  const csvRows = details
    ? bills.flatMap((b) => b.lines.map((l) => [b.outlet, b.date, b.session, b.number, b.buyerName, b.gstin, l.item, l.hsn, l.uqc, l.qty, l.rate, l.taxable, l.cgst, l.sgst, l.igst]))
    : bills.map((b) => [b.outlet, b.date, b.session, b.number, b.buyerName, b.gstin, b.taxable, b.discount, b.service, b.cgst, b.sgst, b.igst, other(b), b.rounding, b.total]);

  const lineHead = ["Item", "HSN / SAC", "Qty", "Rate %", "Taxable value", "CGST", "SGST", ...(hasIgst ? ["IGST"] : []), "Item total"];

  return (
    <ReportShell
      ctx={ctx}
      title="Sales bill-wise register"
      basePath="/reports/sales-billwise"
      basis="finished bills · one line per bill · by business day"
      landscape
      toggles={toggles}
      excel={bills.length > 0 ? { filename: `sales_billwise_${details ? "details" : "summary"}_${from}_${to}.csv`, header: csvHead, rows: csvRows } : null}
    >
      {err ? <Err e={err} /> : bills.length === 0 ? <Empty text="No finished bills in this period." /> : (
        <div className="space-y-6">
          {!details ? (
            <div className="rpt-scroll">
              <table className="rpt-table rpt-zebra">
                <thead><tr>{head.map((h, i) => <th key={h} scope="col" className={textCols.includes(i) ? "text-left" : "text-right"}>{h}</th>)}</tr></thead>
                {groups.map((g) => (
                  <tbody key={g.name || "all"}>
                    {scope.all && <tr><td colSpan={head.length} className="text-left font-bold" style={{ background: "var(--color-brand-soft)" }}>Outlet: {g.name}</td></tr>}
                    {g.list.map((b, i) => <tr key={`${b.number}-${i}`}>{cells(b).map((cell, j) => <td key={j} className={textCols.includes(j) ? "text-left" : "text-right"}>{cell}</td>)}</tr>)}
                    {scope.all && <tr className="rpt-total">{totals(`Outlet total (${g.list.length} bills)`, g.list).map((cell, j) => <td key={j} className={textCols.includes(j) ? "text-left" : "text-right"}>{cell}</td>)}</tr>}
                  </tbody>
                ))}
                <tfoot><tr className="rpt-total">{totals(`GRAND TOTAL (${bills.length} bills)`, bills).map((cell, j) => <td key={j} className={textCols.includes(j) ? "text-left" : "text-right"}>{cell}</td>)}</tr></tfoot>
              </table>
            </div>
          ) : (
            <div className="space-y-4">
              {groups.map((g) => (
                <div key={g.name || "all"} className="space-y-3">
                  {scope.all && <h2 className="text-sm font-bold" style={{ background: "var(--color-brand-soft)", padding: "0.35rem 0.6rem", borderRadius: "0.4rem" }}>Outlet: {g.name}</h2>}
                  {g.list.map((b, i) => (
                    <div key={`${b.number}-${i}`}>
                      <p className="mb-1 text-sm font-semibold">
                        {b.number}{b.comp ? " · complimentary" : ""} · {b.date} · {b.session}{b.buyerName ? ` · ${b.buyerName}` : ""}{b.gstin ? ` · GSTIN ${b.gstin}` : ""}
                      </p>
                      <ReportTable
                        head={lineHead}
                        textCols={[0, 1]}
                        rows={b.lines.map((l) => [l.item, l.hsn || "—", String(l.qty), `${l.rate}%`, m(l.taxable), m(l.cgst), m(l.sgst), ...(hasIgst ? [m(l.igst)] : []), m(l.taxable + l.cgst + l.sgst + l.igst)])}
                        total={[`Bill total (round off ${m(b.rounding)})`, "", "", "", m(b.taxable), m(b.cgst), m(b.sgst), ...(hasIgst ? [m(b.igst)] : []), m(b.total)]}
                      />
                    </div>
                  ))}
                  {scope.all && <p className="text-sm font-bold">Outlet total ({g.list.length} bills): taxable {m(sum(g.list, (b) => b.taxable))} · tax {m(sum(g.list, (b) => b.tax))} · bill amount {m(sum(g.list, (b) => b.total))}</p>}
                </div>
              ))}
              <p className="text-sm font-bold">GRAND TOTAL ({bills.length} bills): taxable {m(sum(bills, (b) => b.taxable))} · tax {m(sum(bills, (b) => b.tax))} · bill amount {m(sum(bills, (b) => b.total))}</p>
            </div>
          )}

          {!details && byRate.length > 0 && (
            <section>
              <h2 className="mb-2 text-sm font-bold">By tax rate</h2>
              <ReportTable head={["Rate", "Taxable value", "CGST", "SGST", "IGST", "Total tax"]} rows={byRate} />
            </section>
          )}

          {truncated && <Note>Only the first 2,000 bills are shown. Choose a shorter period to see the rest.</Note>}
          <Note>
            Taxable value and tax come from the tax lines saved on each bill. &quot;Bill amount&quot; is the amount charged after service charge and round off, so it is not simply taxable value plus tax. Complimentary bills are listed and marked.
          </Note>
        </div>
      )}
    </ReportShell>
  );
}
