import { dateTime, money, orderTypeLabel } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { ageText, csvWithFooter, parsePendingBills } from "@/lib/reports-pack-2";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function PendingBillsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Pending bills" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  // Open bills (still being served) and finished bills that are not fully paid. Totals are worked out in the database.
  const { data, error } = await supabase.rpc("report_pending_bills", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const { rows, totals } = err ? { rows: [], totals: { bills: 0, amount: 0, paid: 0, balance: 0 } } : parsePendingBills(data as unknown);

  const head = ["Bill", "Kind", "Date", "Opened", "Age", "Table", "Type", "Waiter / cashier", ...(scope.all ? ["Outlet"] : []), "Amount", "Paid", "Balance"];
  const textCount = head.length - 3;
  const kindText = (k: "open" | "unsettled") => (k === "open" ? "Open" : "Unsettled");
  const line = (b: (typeof rows)[number]) => [
    b.billNumber || "—",
    kindText(b.kind),
    b.businessDate,
    dateTime(b.createdAt, user.timezone),
    ageText(b.ageMinutes),
    b.table ?? "—",
    orderTypeLabel[b.orderType] ?? (b.orderType || "—"),
    b.waiter ?? b.cashier ?? "—",
    ...(scope.all ? [b.outletName] : []),
  ];

  return (
    <ReportShell
      ctx={ctx}
      title="Pending bills"
      basePath="/reports/pending-bills"
      basis="open bills and bills not fully paid · bills of the chosen days"
      landscape
      excel={
        rows.length > 0
          ? {
              filename: `pending_bills_${from}_${to}.csv`,
              header: head,
              rows: csvWithFooter(
                head.length,
                rows.map((b) => [...line(b), b.amount, b.paid, b.balance]),
                [`TOTAL (${totals.bills} bills)`, ...Array<string>(textCount - 1).fill(""), totals.amount, totals.paid, totals.balance],
                null,
              ),
            }
          : null
      }
    >
      <div>
        {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No open or unpaid bills for this period." /> : (
          <>
            <ReportTable
              groupBy={scope.all ? { col: head.indexOf("Outlet"), sums: { [head.length - 3]: rows.map((b) => b.amount), [head.length - 2]: rows.map((b) => b.paid), [head.length - 1]: rows.map((b) => b.balance) }, format: (_, v) => money(v, c) } : undefined}
              head={head}
              textCols={Array.from({ length: textCount }, (_, i) => i)}
              rows={rows.map((b) => [...line(b), money(b.amount, c), money(b.paid, c), money(b.balance, c)])}
              total={[`TOTAL (${totals.bills} bills)`, ...Array<string>(textCount - 1).fill(""), money(totals.amount, c), money(totals.paid, c), money(totals.balance, c)]}
            />
            <Note>
              Open means the bill is still running (amount so far; paid is any advance taken). Unsettled means the bill was finished but not fully paid. Oldest first.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
