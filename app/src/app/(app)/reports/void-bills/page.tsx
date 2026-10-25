import { dateTime, money, orderTypeLabel } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { csvWithFooter, parseVoidBills, truncationNote } from "@/lib/reports-pack-2";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function VoidBillsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Void bills" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_void_bills", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const parsed = err ? null : parseVoidBills(data as unknown);
  const rows = parsed?.rows ?? [];
  const totals = parsed?.totals ?? { bills: 0, amount: 0 };
  const cut = parsed ? truncationNote(parsed.cap, "bills") : null;

  const head = ["Bill", "Date", "Voided at", "Table", "Type", "Voided by", "Reason", ...(scope.all ? ["Outlet"] : []), "Amount"];
  const line = (b: (typeof rows)[number]) => [
    b.billNumber || "—",
    b.businessDate,
    dateTime(b.voidedAt, user.timezone),
    b.table ?? "—",
    orderTypeLabel[b.orderType] ?? (b.orderType || "—"),
    b.voidedBy ?? "—",
    b.reason ?? "—",
    ...(scope.all ? [b.outletName] : []),
  ];
  const textCount = head.length - 1;

  return (
    <ReportShell
      ctx={ctx}
      title="Void bills"
      basePath="/reports/void-bills"
      basis="bills that were voided · by business day"
      excel={
        rows.length > 0
          ? {
              filename: `void_bills_${from}_${to}.csv`,
              header: head,
              rows: csvWithFooter(
                head.length,
                rows.map((b) => [...line(b), b.amount]),
                [`TOTAL (${totals.bills} bills)`, ...Array<string>(textCount - 1).fill(""), totals.amount],
                parsed?.cap ?? null,
              ),
            }
          : null
      }
    >
      <div>
        {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No bills were voided in this period." /> : (
          <>
            {cut && <Note>{cut}</Note>}
            <ReportTable
              head={head}
              textCols={Array.from({ length: textCount }, (_, i) => i)}
              rows={rows.map((b) => [...line(b), money(b.amount, c)])}
              total={[`TOTAL (${totals.bills} bills)`, ...Array<string>(textCount - 1).fill(""), money(totals.amount, c)]}
            />
            <Note>The amount is the bill total before it was voided. The reason and the person come from the void record.</Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
