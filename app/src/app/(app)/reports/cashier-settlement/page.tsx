import { money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

type Cell = { name: string; method: string; payments: number; bills: number; amount: number };
type Result = { cells: Cell[]; refunds: { name: string; count: number; amount: number }[]; totals: { payments: number; amount: number; refunds: number } };

export default async function CashierSettlementPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Cashier settlement", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_cashier_settlement", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const s = err ? null : (data as unknown as Result);

  const modes = s ? [...new Set(s.cells.map((x) => x.method))] : [];
  const names = s ? [...new Set(s.cells.map((x) => x.name))] : [];
  const amt = (n: string, m: string) => s?.cells.filter((x) => x.name === n && x.method === m).reduce((t, x) => t + Number(x.amount), 0) ?? 0;
  const head = ["Cashier", ...modes, "Total collected"];
  const rows = names.map((n) => {
    const per = modes.map((m) => amt(n, m));
    return [n, ...per.map((v) => money(v, c)), money(per.reduce((t, v) => t + v, 0), c)];
  });
  const totalRow = ["TOTAL", ...modes.map((m) => money(names.reduce((t, n) => t + amt(n, m), 0), c)), money(Number(s?.totals.amount ?? 0), c)];
  const csv = names.map((n) => {
    const per = modes.map((m) => amt(n, m));
    return [n, ...per, per.reduce((t, v) => t + v, 0)];
  });

  return (
    <ReportShell
      ctx={ctx}
      title="Cashier settlement"
      basePath="/reports/cashier-settlement"
      basis="payments on finished bills, by who took the payment"
      landscape
      excel={names.length > 0 ? { filename: `cashier_settlement_${from}_${to}.csv`, header: head, rows: csv } : null}
    >
      <div>
        {err || !s ? <Err e={err ?? { message: "Could not load the report." }} /> : names.length === 0 ? <Empty text="No payments in this period." /> : (
          <div className="space-y-6">
            <section>
              <h2 className="mb-2 text-sm font-bold">Collected by each cashier</h2>
              <ReportTable head={head} textCols={[0]} rows={rows} total={totalRow} />
              <Note>Each amount is what that person took in that payment mode, including any cash rounding. Check each cashier&apos;s cash against their drawer count.</Note>
            </section>
            <section>
              <h2 className="mb-2 text-sm font-bold">Refunds approved</h2>
              {s.refunds.length === 0 ? (
                <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No refunds in this period.</p>
              ) : (
                <ReportTable
                  head={["Approved by", "Refunds", "Amount"]}
                  textCols={[0]}
                  rows={s.refunds.map((x) => [x.name, String(x.count), money(Number(x.amount), c)])}
                  total={["TOTAL", String(s.refunds.reduce((t, x) => t + Number(x.count), 0)), money(Number(s.totals.refunds), c)]}
                />
              )}
              <p className="mt-2 text-sm font-bold">Net collected: {money(Number(s.totals.amount) - Number(s.totals.refunds), c)}</p>
            </section>
          </div>
        )}
      </div>
    </ReportShell>
  );
}
