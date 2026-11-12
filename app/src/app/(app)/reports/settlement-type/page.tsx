import { longDate, money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";

type Cell = { outlet: string; date: string; kind: string; method: string; payments: number; amount: number };

const KIND_LABEL: Record<string, string> = { cash: "Cash", card: "Card", upi: "UPI", account: "Customer account", advance: "Advance adjusted", gift_card: "Gift card", loyalty: "Loyalty points", other: "Other" };

/**
 * Settlement type (as Winsar's "Settlement Type"): for each day, how much was paid in each payment mode, with a column for every
 * mode, outlet totals when several outlets are in view, and a grand total. Tick "Group by type" to add up modes of the same kind.
 */
export default async function SettlementTypePage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; kind?: string }> }) {
  const sp = await searchParams;
  const byKind = sp.kind === "1";
  const r = await loadReport(sp, { title: "Settlement type", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  const m = (x: number) => (x === 0 ? "—" : money(x, c));

  const { data, error } = await supabase.rpc("report_settlement_type", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const cells: Cell[] = err ? [] : asList(asObj(data).rows).map((x) => ({ outlet: s(x.outlet_name, "Unknown outlet"), date: s(x.business_date), kind: s(x.kind, "other"), method: s(x.method), payments: n(x.payments), amount: n(x.amount) }));
  const label = (x: Cell) => (byKind ? KIND_LABEL[x.kind] ?? x.kind : x.method);
  const cols = [...new Set(cells.map(label))].sort((a, b) => a.localeCompare(b));
  const groups = scope.all ? [...new Set(cells.map((x) => x.outlet))].sort().map((name) => ({ name, list: cells.filter((x) => x.outlet === name) })) : [{ name: "", list: cells }];

  const amountOf = (list: Cell[], col: string, date?: string) => list.filter((x) => label(x) === col && (date == null || x.date === date)).reduce((a, x) => a + x.amount, 0);
  const rowOf = (list: Cell[], date: string) => cols.map((col) => amountOf(list, col, date));
  const dates = (list: Cell[]) => [...new Set(list.map((x) => x.date))].sort();
  const total = (xs: number[]) => xs.reduce((a, x) => a + x, 0);

  const head = ["Date", ...cols, "Total"];
  const csvRows: (string | number)[][] = [];
  for (const g of groups) {
    for (const d of dates(g.list)) { const v = rowOf(g.list, d); csvRows.push([...(scope.all ? [g.name] : []), d, ...v, total(v)]); }
  }
  const csvHead = scope.all ? ["Outlet", ...head] : head;

  return (
    <ReportShell
      ctx={ctx}
      title="Settlement type"
      basePath="/reports/settlement-type"
      basis="payments on finished bills · by business day"
      landscape
      toggles={[{ name: "kind", label: "Group by type (cash, card, UPI…)", checked: byKind }]}
      excel={cells.length > 0 ? { filename: `settlement_type_${from}_${to}.csv`, header: csvHead, rows: csvRows } : null}
    >
      {err ? <Err e={err} /> : cells.length === 0 ? <Empty text="No payments in this period." /> : (
        <div className="space-y-4">
          <div className="rpt-scroll">
            <table className="rpt-table rpt-zebra">
              <thead><tr>{head.map((h, i) => <th key={h} scope="col" className={i === 0 ? "text-left" : "text-right"}>{h}</th>)}</tr></thead>
              {groups.map((g) => (
                <tbody key={g.name || "all"}>
                  {scope.all && <tr><td colSpan={head.length} className="text-left font-bold" style={{ background: "var(--color-brand-soft)" }}>Outlet: {g.name}</td></tr>}
                  {dates(g.list).map((d) => { const v = rowOf(g.list, d); return (
                    <tr key={d}><td className="text-left">{longDate(d)}</td>{v.map((x, i) => <td key={i} className="text-right">{m(x)}</td>)}<td className="text-right font-semibold">{money(total(v), c)}</td></tr>
                  ); })}
                  {scope.all && (() => { const v = cols.map((col) => amountOf(g.list, col)); return <tr className="rpt-total"><td className="text-left">Outlet total</td>{v.map((x, i) => <td key={i} className="text-right">{money(x, c)}</td>)}<td className="text-right">{money(total(v), c)}</td></tr>; })()}
                </tbody>
              ))}
              <tfoot>
                {(() => { const v = cols.map((col) => amountOf(cells, col)); return <tr className="rpt-total"><td className="text-left">GRAND TOTAL</td>{v.map((x, i) => <td key={i} className="text-right">{money(x, c)}</td>)}<td className="text-right">{money(total(v), c)}</td></tr>; })()}
              </tfoot>
            </table>
          </div>
          <Note>Amounts are what customers paid on finished bills, including cash rounding. &quot;Advance adjusted&quot; is a pre-order advance applied to the bill, not new money. Refunds are not taken off here; see Settlement.</Note>
        </div>
      )}
    </ReportShell>
  );
}
