import { dateTime, money } from "@/lib/format";
import { methodLabel } from "@/lib/reports-pack-2";

type Pay = { billNumber: string; businessDate: string; method: string; amount: number; receivedBy: string | null; outletName: string; paidAt?: string | null; referenceNo?: string | null };

/** Settlement with one line per bill and one column for each payment mode, ending in a total for the whole period. */
export function BillsByMode({ rows, currency, showOutlet, showTime = false, showRef = false, timezone = "UTC" }: { rows: Pay[]; currency: string; showOutlet: boolean; showTime?: boolean; showRef?: boolean; timezone?: string }) {
  const m = (n: number) => (n === 0 ? "—" : money(n, currency));
  const modes = [...new Set(rows.map((p) => methodLabel(p.method)))].sort((a, b) => a.localeCompare(b));
  const bills = new Map<string, { bill: string; date: string; outlet: string; by: string; time: string; refs: Set<string>; paid: Map<string, number> }>();
  for (const p of rows) {
    const key = `${p.outletName}|${p.billNumber}`;
    const b = bills.get(key) ?? { bill: p.billNumber || "—", date: p.businessDate, outlet: p.outletName, by: p.receivedBy ?? "—", time: p.paidAt ? dateTime(p.paidAt, timezone) : "—", refs: new Set<string>(), paid: new Map<string, number>() };
    if (p.referenceNo) b.refs.add(p.referenceNo);
    const label = methodLabel(p.method);
    b.paid.set(label, (b.paid.get(label) ?? 0) + p.amount);
    bills.set(key, b);
  }
  const list = [...bills.values()].sort((a, b) => a.outlet.localeCompare(b.outlet) || a.date.localeCompare(b.date) || a.bill.localeCompare(b.bill, undefined, { numeric: true }));
  const rowTotal = (b: (typeof list)[number]) => [...b.paid.values()].reduce((a, x) => a + x, 0);
  const modeTotal = (mode: string) => list.reduce((a, b) => a + (b.paid.get(mode) ?? 0), 0);
  const lead = ["Bill", "Date", ...(showTime ? ["Time"] : []), "Received by", ...(showOutlet ? ["Outlet"] : []), ...(showRef ? ["Reference"] : [])];

  return (
    <div className="rpt-scroll">
      <table className="rpt-table rpt-zebra">
        <thead>
          <tr>
            {[...lead, ...modes, "Total"].map((h, i) => <th key={`${h}-${i}`} scope="col" className={i < lead.length ? "text-left" : "text-right"}>{h}</th>)}
          </tr>
        </thead>
        <tbody>
          {list.map((b, i) => (
            <tr key={i}>
              {[b.bill, b.date, ...(showTime ? [b.time] : []), b.by, ...(showOutlet ? [b.outlet] : []), ...(showRef ? [[...b.refs].join(", ") || "—"] : [])].map((x, j) => <td key={j} className="text-left">{x}</td>)}
              {modes.map((mode) => <td key={mode} className="text-right">{m(b.paid.get(mode) ?? 0)}</td>)}
              <td className="text-right font-semibold">{money(rowTotal(b), currency)}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="rpt-total">
            <td className="text-left">{`TOTAL (${list.length} bills)`}</td>
            {Array.from({ length: lead.length - 1 }, (_, i) => <td key={i} />)}
            {modes.map((mode) => <td key={mode} className="text-right">{money(modeTotal(mode), currency)}</td>)}
            <td className="text-right">{money(list.reduce((a, b) => a + rowTotal(b), 0), currency)}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
