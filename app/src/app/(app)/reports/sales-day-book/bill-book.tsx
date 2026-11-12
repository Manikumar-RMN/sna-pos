import { money } from "@/lib/format";
import { paymentsText, type BillDetail } from "@/lib/reports-pack-2";

const sum = (rows: BillDetail[], f: (b: BillDetail) => number) => rows.reduce((a, b) => a + f(b), 0);
const settled = (b: BillDetail) => b.payments.reduce((a, x) => a + x.amount, 0);
const otherTax = (b: BillDetail) => b.tax - b.cgst - b.sgst - b.igst;

/** Which tax columns this set of bills needs: CGST / SGST always when split, IGST and Other tax only when they have amounts. */
export function taxColumns(rows: BillDetail[]) {
  const split = rows.some((b) => b.cgst || b.sgst || b.igst);
  return {
    split,
    igst: split && rows.some((b) => b.igst),
    other: split && rows.some((b) => Math.abs(otherTax(b)) > 0.005),
  };
}

/**
 * The Sales day book with one line per bill (Session, Bill, Covers, amounts, tax split as CGST / SGST, round-off, bill and settled amount).
 * When several outlets are in view the bills are grouped by outlet, each group ends with an outlet subtotal, and the book ends with a grand total.
 */
export function BillBook({ rows, currency, grouped }: { rows: BillDetail[]; currency: string; grouped: boolean }) {
  const m = (n: number) => money(n, currency);
  const tc = taxColumns(rows);
  type Col = { head: string; text?: boolean; cell: (b: BillDetail) => string; total?: (l: BillDetail[]) => string };
  const cols: Col[] = [
    { head: "Date", text: true, cell: (b) => b.businessDate },
    { head: "Session", text: true, cell: (b) => b.session },
    { head: "Bill", text: true, cell: (b) => b.billNumber || "—" },
    { head: "Table", text: true, cell: (b) => b.table ?? "—" },
    { head: "Covers", cell: (b) => (b.covers == null ? "—" : String(b.covers)), total: (l) => String(sum(l, (b) => b.covers ?? 0)) },
    { head: "Gross", cell: (b) => m(b.subtotal), total: (l) => m(sum(l, (b) => b.subtotal)) },
    { head: "Discount", cell: (b) => m(b.discount), total: (l) => m(sum(l, (b) => b.discount)) },
    { head: "Service", cell: (b) => m(b.serviceCharge), total: (l) => m(sum(l, (b) => b.serviceCharge)) },
    ...(tc.split
      ? [
          { head: "CGST", cell: (b: BillDetail) => m(b.cgst), total: (l: BillDetail[]) => m(sum(l, (b) => b.cgst)) },
          { head: "SGST", cell: (b: BillDetail) => m(b.sgst), total: (l: BillDetail[]) => m(sum(l, (b) => b.sgst)) },
          ...(tc.igst ? [{ head: "IGST", cell: (b: BillDetail) => m(b.igst), total: (l: BillDetail[]) => m(sum(l, (b) => b.igst)) }] : []),
          ...(tc.other ? [{ head: "Other tax", cell: (b: BillDetail) => m(otherTax(b)), total: (l: BillDetail[]) => m(sum(l, otherTax)) }] : []),
        ]
      : [{ head: "Tax", cell: (b: BillDetail) => m(b.tax), total: (l: BillDetail[]) => m(sum(l, (b) => b.tax)) }]),
    { head: "Rounding", cell: (b) => m(b.rounding), total: (l) => m(sum(l, (b) => b.rounding)) },
    { head: "Bill amount", cell: (b) => m(b.grandTotal), total: (l) => m(sum(l, (b) => b.grandTotal)) },
    { head: "Settled", cell: (b) => m(settled(b)), total: (l) => m(sum(l, settled)) },
    { head: "Paid by", text: true, cell: (b) => paymentsText(b.payments, m) || "—" },
  ];
  const sorted = [...rows].sort((a, b) => a.outletName.localeCompare(b.outletName) || a.businessDate.localeCompare(b.businessDate) || a.billNumber.localeCompare(b.billNumber, undefined, { numeric: true }));
  const groups = grouped ? [...new Set(sorted.map((b) => b.outletName))].map((name) => ({ name, list: sorted.filter((b) => b.outletName === name) })) : [{ name: "", list: sorted }];
  const al = (c: Col) => (c.text ? "text-left" : "text-right");
  const totalRow = (label: string, list: BillDetail[]) => cols.map((c, i) => (i === 0 ? label : c.total ? c.total(list) : ""));

  return (
    <div className="rpt-scroll">
      <table className="rpt-table rpt-zebra">
        <thead>
          <tr>{cols.map((c) => <th key={c.head} scope="col" className={al(c)}>{c.head}</th>)}</tr>
        </thead>
        {groups.map((g) => (
          <tbody key={g.name || "all"}>
            {grouped && (
              <tr><td colSpan={cols.length} className="text-left font-bold" style={{ background: "var(--color-brand-soft)" }}>Outlet: {g.name}</td></tr>
            )}
            {g.list.map((b, i) => (
              <tr key={`${b.billNumber}-${i}`}>
                {cols.map((c) => <td key={c.head} className={al(c)}>{c.cell(b)}</td>)}
              </tr>
            ))}
            {grouped && (
              <tr className="rpt-total">
                {totalRow(`Outlet total (${g.list.length} bills)`, g.list).map((cell, j) => <td key={j} className={al(cols[j])}>{cell}</td>)}
              </tr>
            )}
          </tbody>
        ))}
        <tfoot>
          <tr className="rpt-total">
            {totalRow(`GRAND TOTAL (${rows.length} bills)`, rows).map((cell, j) => <td key={j} className={al(cols[j])}>{cell}</td>)}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
