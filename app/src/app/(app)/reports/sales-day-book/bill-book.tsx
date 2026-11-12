import { money } from "@/lib/format";
import { paymentsText, type BillDetail } from "@/lib/reports-pack-2";

const sum = (rows: BillDetail[], f: (b: BillDetail) => number) => rows.reduce((a, b) => a + f(b), 0);
const settled = (b: BillDetail) => b.payments.reduce((a, x) => a + x.amount, 0);

/**
 * The Sales day book with one line per bill. When several outlets are in view the bills are grouped by outlet,
 * each group ends with an outlet subtotal, and the book ends with a grand total.
 */
export function BillBook({ rows, currency, grouped }: { rows: BillDetail[]; currency: string; grouped: boolean }) {
  const m = (n: number) => money(n, currency);
  const head = ["Date", "Bill", "Table", "Covers", "Gross", "Discount", "Service", "Tax", "Rounding", "Bill amount", "Settled", "Paid by"];
  const textCols = [0, 1, 2, 11];
  const numbers = (list: BillDetail[]) => [
    sum(list, (b) => b.subtotal), sum(list, (b) => b.discount), sum(list, (b) => b.serviceCharge), sum(list, (b) => b.tax), sum(list, (b) => b.rounding), sum(list, (b) => b.grandTotal), sum(list, settled),
  ].map(m);
  const sorted = [...rows].sort((a, b) => a.outletName.localeCompare(b.outletName) || a.businessDate.localeCompare(b.businessDate) || a.billNumber.localeCompare(b.billNumber, undefined, { numeric: true }));
  const groups = grouped ? [...new Set(sorted.map((b) => b.outletName))].map((name) => ({ name, list: sorted.filter((b) => b.outletName === name) })) : [{ name: "", list: sorted }];
  const al = (i: number) => (textCols.includes(i) ? "text-left" : "text-right");
  const cols = head.length;

  return (
    <div className="rpt-scroll">
      <table className="rpt-table rpt-zebra">
        <thead>
          <tr>{head.map((h, i) => <th key={h} scope="col" className={al(i)}>{h}</th>)}</tr>
        </thead>
        {groups.map((g) => (
          <tbody key={g.name || "all"}>
            {grouped && (
              <tr><td colSpan={cols} className="text-left font-bold" style={{ background: "var(--color-brand-soft)" }}>Outlet: {g.name}</td></tr>
            )}
            {g.list.map((b, i) => (
              <tr key={`${b.billNumber}-${i}`}>
                {[b.businessDate, b.billNumber || "—", b.table ?? "—", b.covers == null ? "—" : String(b.covers), m(b.subtotal), m(b.discount), m(b.serviceCharge), m(b.tax), m(b.rounding), m(b.grandTotal), m(settled(b)), paymentsText(b.payments, m) || "—"].map((cell, j) => (
                  <td key={j} className={al(j)}>{cell}</td>
                ))}
              </tr>
            ))}
            {grouped && (
              <tr className="rpt-total">
                {[`Outlet total (${g.list.length} bills)`, "", "", String(sum(g.list, (b) => b.covers ?? 0)), ...numbers(g.list), ""].map((cell, j) => <td key={j} className={al(j)}>{cell}</td>)}
              </tr>
            )}
          </tbody>
        ))}
        <tfoot>
          <tr className="rpt-total">
            {[`GRAND TOTAL (${rows.length} bills)`, "", "", String(sum(rows, (b) => b.covers ?? 0)), ...numbers(rows), ""].map((cell, j) => <td key={j} className={al(j)}>{cell}</td>)}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
