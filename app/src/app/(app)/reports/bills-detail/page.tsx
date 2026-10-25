import { dateTime, money, orderTypeLabel } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { compLabel, csvWithFooter, parseBillsDetail, paymentsText, truncationNote } from "@/lib/reports-pack-2";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function BillsDetailPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Bills detail", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_bills_detail", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const parsed = err ? null : parseBillsDetail(data as unknown);
  const rows = parsed?.rows ?? [];
  const totals = parsed?.totals;
  const cut = parsed ? truncationNote(parsed.cap, "bills") : null;

  const lead = ["Bill", "Date", "Time", "Table", "Type", "Waiter / cashier", "Covers", ...(scope.all ? ["Outlet"] : []), "Note"];
  const head = [...lead, "Subtotal", "Discount", "Service", "Tax", "Rounding", "Total", "Paid by"];
  const line = (b: (typeof rows)[number]) => [
    b.billNumber || "—",
    b.businessDate,
    dateTime(b.createdAt, user.timezone),
    b.table ?? "—",
    orderTypeLabel[b.orderType] ?? (b.orderType || "—"),
    b.waiter ?? b.cashier ?? "—",
    b.covers == null ? "—" : String(b.covers),
    ...(scope.all ? [b.outletName] : []),
    compLabel(b.compKind) || (b.paymentStatus && b.paymentStatus !== "paid" ? b.paymentStatus : ""),
  ];
  const textCols = [...lead.map((_, i) => i), head.length - 1];

  return (
    <ReportShell
      ctx={ctx}
      title="Bills detail"
      basePath="/reports/bills-detail"
      basis="finished bills · by business day · complimentary and staff-meal bills included"
      landscape
      excel={
        rows.length > 0
          ? {
              filename: `bills_detail_${from}_${to}.csv`,
              header: head,
              rows: csvWithFooter(
                head.length,
                rows.map((b) => [...line(b), b.subtotal, b.discount, b.serviceCharge, b.tax, b.rounding, b.grandTotal, paymentsText(b.payments, (n) => n.toFixed(2))]),
                totals
                  ? [`TOTAL (${totals.bills} bills)`, ...Array<string>(lead.length - 1).fill(""), totals.subtotal, totals.discount, totals.serviceCharge, totals.tax, totals.rounding, totals.grandTotal]
                  : null,
                parsed?.cap ?? null,
              ),
            }
          : null
      }
    >
      <div>
        {err ? <Err e={err} /> : rows.length === 0 || !totals ? <Empty text="No finished bills in this period." /> : (
          <>
            {cut && <Note>{cut}</Note>}
            <ReportTable
              head={head}
              textCols={textCols}
              zebra
              rows={rows.map((b) => [
                ...line(b),
                money(b.subtotal, c),
                money(b.discount, c),
                money(b.serviceCharge, c),
                money(b.tax, c),
                money(b.rounding, c),
                money(b.grandTotal, c),
                paymentsText(b.payments, (n) => money(n, c)) || "—",
              ])}
              total={[
                `TOTAL (${totals.bills} bills)`,
                ...Array<string>(lead.length - 1).fill(""),
                money(totals.subtotal, c),
                money(totals.discount, c),
                money(totals.serviceCharge, c),
                money(totals.tax, c),
                money(totals.rounding, c),
                money(totals.grandTotal, c),
                "",
              ]}
            />
            <Note>
              The TOTAL row comes from the database and covers every bill in the period{cut ? ", not only the rows shown" : ""}. Oldest bill first.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
