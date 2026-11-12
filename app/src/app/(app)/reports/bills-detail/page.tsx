import { dateTime, money, orderTypeLabel } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { paymentStatusLabel } from "@/lib/reports-pack-3";
import { compLabel, csvWithFooter, parseBillsDetail, paymentsText, truncationNote } from "@/lib/reports-pack-2";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function BillsDetailPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; session?: string; customer?: string; taxsplit?: string; tips?: string; items?: string; compact?: string }> }) {
  const sp = await searchParams;
  const on = { session: sp.session === "1", customer: sp.customer === "1", taxsplit: sp.taxsplit === "1", tips: sp.tips === "1", items: sp.items === "1", compact: sp.compact === "1" };
  const r = await loadReport(sp, { title: "Bills detail", need: "financial" });
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

  type Bill = (typeof rows)[number];
  type Col = { head: string; text?: boolean; cell: (b: Bill) => string; num?: (b: Bill) => number | string; total?: number };
  const t = totals;
  const cols: Col[] = [
    { head: "Bill", text: true, cell: (b) => b.billNumber || "—" },
    { head: "Date", text: true, cell: (b) => b.businessDate },
    ...(on.compact ? [] : [{ head: "Time", text: true, cell: (b: Bill) => dateTime(b.createdAt, user.timezone) }]),
    ...(on.session ? [{ head: "Session", text: true, cell: (b: Bill) => b.session }] : []),
    { head: "Table", text: true, cell: (b) => b.table ?? "—" },
    ...(on.compact ? [] : [{ head: "Type", text: true, cell: (b: Bill) => orderTypeLabel[b.orderType] ?? (b.orderType || "—") }]),
    ...(on.compact ? [] : [{ head: "Waiter / cashier", text: true, cell: (b: Bill) => b.waiter ?? b.cashier ?? "—" }]),
    { head: "Covers", text: true, cell: (b) => (b.covers == null ? "—" : String(b.covers)) },
    ...(scope.all ? [{ head: "Outlet", text: true, cell: (b: Bill) => b.outletName }] : []),
    ...(on.customer ? [{ head: "Customer", text: true, cell: (b: Bill) => b.buyerName ?? "—" }, { head: "GST No", text: true, cell: (b: Bill) => b.buyerGstin ?? "—" }] : []),
    { head: "Note", text: true, cell: (b) => compLabel(b.compKind) || paymentStatusLabel(b.paymentStatus) },
    ...(on.items ? [{ head: "Items", text: true, cell: (b: Bill) => b.items ?? "—" }] : []),
  ];
  const amountCols: { head: string; value: (b: Bill) => number; total: number }[] = [
    { head: "Subtotal", value: (b) => b.subtotal, total: t?.subtotal ?? 0 },
    { head: "Discount", value: (b) => b.discount, total: t?.discount ?? 0 },
    { head: "Service", value: (b) => b.serviceCharge, total: t?.serviceCharge ?? 0 },
    ...(on.taxsplit
      ? [
          { head: "CGST", value: (b: Bill) => b.cgst, total: rows.reduce((a, b) => a + b.cgst, 0) },
          { head: "SGST", value: (b: Bill) => b.sgst, total: rows.reduce((a, b) => a + b.sgst, 0) },
          ...(rows.some((b) => b.igst) ? [{ head: "IGST", value: (b: Bill) => b.igst, total: rows.reduce((a, b) => a + b.igst, 0) }] : []),
          ...(rows.some((b) => Math.abs(b.tax - b.cgst - b.sgst - b.igst) > 0.005) ? [{ head: "Other tax", value: (b: Bill) => b.tax - b.cgst - b.sgst - b.igst, total: rows.reduce((a, b) => a + b.tax - b.cgst - b.sgst - b.igst, 0) }] : []),
        ]
      : [{ head: "Tax", value: (b: Bill) => b.tax, total: t?.tax ?? 0 }]),
    { head: "Rounding", value: (b) => b.rounding, total: t?.rounding ?? 0 },
    { head: "Total", value: (b) => b.grandTotal, total: t?.grandTotal ?? 0 },
    ...(on.tips ? [{ head: "Tips", value: (b: Bill) => b.tips, total: rows.reduce((a, b) => a + b.tips, 0) }] : []),
  ];
  const lead = cols.map((c) => c.head);
  const head = [...lead, ...amountCols.map((a) => a.head), "Paid by"];
  const textCols = [...lead.map((_, i) => i), head.length - 1];
  const line = (b: Bill) => cols.map((c) => c.cell(b));
  const toggles = [
    { name: "session", label: "Session", checked: on.session },
    { name: "customer", label: "Customer and GST No", checked: on.customer },
    { name: "taxsplit", label: "Tax split (CGST / SGST / IGST)", checked: on.taxsplit },
    { name: "items", label: "Items on each bill", checked: on.items },
    { name: "tips", label: "Tips", checked: on.tips },
    { name: "compact", label: "Compact (hide time, type, waiter)", checked: on.compact },
  ];

  return (
    <ReportShell
      ctx={ctx}
      title="Bills detail"
      basePath="/reports/bills-detail"
      basis="finished bills · by business day · complimentary and staff-meal bills included"
      landscape
      toggles={toggles}
      excel={
        rows.length > 0
          ? {
              filename: `bills_detail_${from}_${to}.csv`,
              header: head,
              rows: csvWithFooter(
                head.length,
                rows.map((b) => [...line(b), ...amountCols.map((a) => a.value(b)), paymentsText(b.payments, (n) => n.toFixed(2))]),
                totals
                  ? [`TOTAL (${totals.bills} bills)`, ...Array<string>(lead.length - 1).fill(""), ...amountCols.map((a) => a.total)]
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
              rows={rows.map((b) => [...line(b), ...amountCols.map((a) => money(a.value(b), c)), paymentsText(b.payments, (n) => money(n, c)) || "—"])}
              total={[`TOTAL (${totals.bills} bills)`, ...Array<string>(lead.length - 1).fill(""), ...amountCols.map((a) => money(a.total, c)), ""]}
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
