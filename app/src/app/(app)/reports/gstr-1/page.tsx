import { money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

type Reg = { type: string; date: string; number: string; status: string; against?: string | null; buyer_gstin: string | null; buyer_name: string | null; taxable: number; cgst: number; sgst: number; igst: number; rate: number | null; total: number };
type Hsn = { supply: string; hsn: string; uqc: string; rate: number; quantity: number; taxable: number; cgst: number; sgst: number; igst: number; total: number };

const n = (v: unknown) => Number(v ?? 0) || 0;
const sum = <T,>(l: T[], f: (x: T) => number) => l.reduce((a, x) => a + f(x), 0);

/**
 * GSTR-1 working sheet for India: the figures an accountant keys into the GST return, from finished bills.
 * Bills to a customer with a GSTIN go bill by bill (B2B); all other bills are added up by tax rate (B2C); credit notes, nil-rated bills,
 * the invoice series and the HSN/SAC summary follow. The GST portal tables are named in each heading.
 */
export default async function Gstr1Page({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "GSTR-1 working sheet", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const m = (v: number) => money(v, c);

  if (user.country_code !== "IN") {
    return (
      <ReportShell ctx={ctx} title="GSTR-1 working sheet" basePath="/reports/gstr-1" basis="India GST only">
        <Empty text="GSTR-1 is the Indian GST return. This report is for outlets in India." />
      </ReportShell>
    );
  }

  const [{ data: regData, error: regErr }, { data: hsnData, error: hsnErr }] = await Promise.all([
    supabase.rpc("gst_register", { p_from: from, p_to: to }),
    supabase.rpc("gstr1_hsn_summary", { p_from: from, p_to: to }),
  ]);
  const err = reportRpcError(regErr) ?? reportRpcError(hsnErr);
  const reg = ((regData ?? []) as unknown as Reg[]).map((x) => ({ ...x, taxable: n(x.taxable), cgst: n(x.cgst), sgst: n(x.sgst), igst: n(x.igst), total: n(x.total), rate: x.rate == null ? null : n(x.rate) }));
  const hsn = ((hsnData ?? []) as unknown as Hsn[]).map((x) => ({ ...x, rate: n(x.rate), quantity: n(x.quantity), taxable: n(x.taxable), cgst: n(x.cgst), sgst: n(x.sgst), igst: n(x.igst), total: n(x.total) }));

  const sales = reg.filter((x) => x.type === "Bill" && x.status === "completed");
  const voided = reg.filter((x) => x.type === "Bill" && x.status === "voided");
  const notes = reg.filter((x) => x.type !== "Bill");
  const b2b = sales.filter((x) => x.buyer_gstin);
  const b2c = sales.filter((x) => !x.buyer_gstin);
  const nilRated = b2c.filter((x) => !x.rate);
  const b2cTaxed = b2c.filter((x) => !!x.rate);
  const rates = [...new Set(b2cTaxed.map((x) => x.rate as number))].sort((a, b) => a - b);
  const numbers = sales.map((x) => x.number).sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

  const csv: (string | number)[][] = [
    ...b2b.map((x) => ["4A B2B", x.number, x.date, x.buyer_gstin ?? "", x.buyer_name ?? "", x.rate ?? "", x.taxable, x.igst, x.cgst, x.sgst, x.total]),
    ...rates.map((rt) => { const l = b2cTaxed.filter((x) => x.rate === rt); return ["7 B2C others", `${l.length} bills`, "", "", "", rt, sum(l, (x) => x.taxable), sum(l, (x) => x.igst), sum(l, (x) => x.cgst), sum(l, (x) => x.sgst), sum(l, (x) => x.total)]; }),
    ...(nilRated.length > 0 ? [["8 Nil rated", `${nilRated.length} bills`, "", "", "", 0, sum(nilRated, (x) => x.taxable), 0, 0, 0, sum(nilRated, (x) => x.total)]] : []),
    ...notes.map((x) => ["9B Credit note", x.number, x.date, x.buyer_gstin ?? "", x.buyer_name ?? "", "", x.taxable, x.igst, x.cgst, x.sgst, x.total]),
    ...hsn.map((x) => [`12 HSN ${x.supply}`, x.hsn, x.uqc, "", "", x.rate, x.taxable, x.igst, x.cgst, x.sgst, x.total]),
  ];

  return (
    <ReportShell
      ctx={ctx}
      title="GSTR-1 working sheet"
      basePath="/reports/gstr-1"
      basis="finished bills and credit notes · by business day · India GST"
      landscape
      excel={csv.length > 0 ? { filename: `gstr1_${from}_${to}.csv`, header: ["Table", "Number / detail", "Date / unit", "GSTIN", "Customer", "Rate %", "Taxable value", "IGST", "CGST", "SGST", "Total"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : reg.length === 0 && hsn.length === 0 ? <Empty text="No bills in this period." /> : (
          <>
            <section>
              <h2 className="mb-2 text-sm font-bold">Table 4A · B2B: bills to a customer with a GSTIN</h2>
              {b2b.length === 0 ? <Empty text="No bills with a customer GSTIN in this period." /> : (
                <ReportTable
                  head={["Invoice", "Date", "Customer GSTIN", "Customer", "Rate %", "Taxable value", "IGST", "CGST", "SGST", "Invoice value"]}
                  textCols={[0, 1, 2, 3]}
                  zebra
                  rows={b2b.map((x) => [x.number, x.date, x.buyer_gstin ?? "", x.buyer_name ?? "—", x.rate == null ? "—" : String(x.rate), m(x.taxable), m(x.igst), m(x.cgst), m(x.sgst), m(x.total)])}
                  total={[`TOTAL (${b2b.length})`, "", "", "", "", m(sum(b2b, (x) => x.taxable)), m(sum(b2b, (x) => x.igst)), m(sum(b2b, (x) => x.cgst)), m(sum(b2b, (x) => x.sgst)), m(sum(b2b, (x) => x.total))]}
                />
              )}
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Table 7 · B2C others: all other bills, added up by tax rate</h2>
              {rates.length === 0 ? <Empty text="No taxed consumer bills in this period." /> : (
                <ReportTable
                  head={["Rate %", "Bills", "Taxable value", "IGST", "CGST", "SGST", "Total"]}
                  textCols={[0]}
                  rows={rates.map((rt) => { const l = b2cTaxed.filter((x) => x.rate === rt); return [String(rt), String(l.length), m(sum(l, (x) => x.taxable)), m(sum(l, (x) => x.igst)), m(sum(l, (x) => x.cgst)), m(sum(l, (x) => x.sgst)), m(sum(l, (x) => x.total))]; })}
                  total={["TOTAL", String(b2cTaxed.length), m(sum(b2cTaxed, (x) => x.taxable)), m(sum(b2cTaxed, (x) => x.igst)), m(sum(b2cTaxed, (x) => x.cgst)), m(sum(b2cTaxed, (x) => x.sgst)), m(sum(b2cTaxed, (x) => x.total))]}
                />
              )}
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Tables 5A/5B · B2C large (inter-state, above ₹1,00,000) and Table 8 · nil-rated</h2>
              <ReportTable
                head={["Group", "Bills", "Value"]}
                textCols={[0]}
                rows={[
                  ["B2C large: inter-state bills to consumers above ₹1,00,000", String(b2c.filter((x) => x.igst > 0 && x.total > 100000).length), m(sum(b2c.filter((x) => x.igst > 0 && x.total > 100000), (x) => x.total))],
                  ["Nil-rated bills (no tax charged)", String(nilRated.length), m(sum(nilRated, (x) => x.total))],
                ]}
              />
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Table 9B · Credit notes</h2>
              {notes.length === 0 ? <Empty text="No credit notes in this period." /> : (
                <ReportTable
                  head={["Credit note", "Date", "Against bill", "Customer GSTIN", "Taxable value", "IGST", "CGST", "SGST", "Value"]}
                  textCols={[0, 1, 2, 3]}
                  rows={notes.map((x) => [x.number, x.date, x.against ?? "—", x.buyer_gstin ?? "Unregistered", m(x.taxable), m(x.igst), m(x.cgst), m(x.sgst), m(x.total)])}
                  total={["TOTAL", "", "", "", m(sum(notes, (x) => x.taxable)), m(sum(notes, (x) => x.igst)), m(sum(notes, (x) => x.cgst)), m(sum(notes, (x) => x.sgst)), m(sum(notes, (x) => x.total))]}
                />
              )}
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Table 12 · HSN / SAC summary (B2B and B2C apart)</h2>
              {hsn.length === 0 ? <Empty text="No items sold in this period." /> : (
                <ReportTable
                  head={["Supply", "HSN / SAC", "Unit", "Rate %", "Quantity", "Taxable value", "IGST", "CGST", "SGST", "Total"]}
                  textCols={[0, 1, 2]}
                  zebra
                  rows={hsn.map((x) => [x.supply, x.hsn, x.uqc, String(x.rate), String(x.quantity), m(x.taxable), m(x.igst), m(x.cgst), m(x.sgst), m(x.total)])}
                  total={["TOTAL", "", "", "", String(sum(hsn, (x) => x.quantity)), m(sum(hsn, (x) => x.taxable)), m(sum(hsn, (x) => x.igst)), m(sum(hsn, (x) => x.cgst)), m(sum(hsn, (x) => x.sgst)), m(sum(hsn, (x) => x.total))]}
                />
              )}
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Table 13 · Invoices issued</h2>
              <ReportTable
                head={["From", "To", "Issued", "Cancelled", "Net issued"]}
                textCols={[0, 1]}
                rows={[[numbers[0] ?? "—", numbers[numbers.length - 1] ?? "—", String(sales.length + voided.length), String(voided.length), String(sales.length)]]}
              />
            </section>

            <Note>
              This is a working sheet for the person who files the return, not the return itself. Bills with a customer GSTIN are listed one by one (B2B); every other bill is added up by tax rate (B2C). Credit notes are shown with their bill. HSN comes from the menu item, or the outlet's SAC when none is set. Check these figures and the file format with your accountant before filing; the portal upload file is not produced here.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
