import { dateTime, money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { csvWithFooter, methodLabel, parseSettlement, settlementByOutlet, truncationNote } from "@/lib/reports-pack-2";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";
import { BillsByMode } from "./bills-by-mode";

export default async function SettlementPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; bybill?: string }> }) {
  const sp = await searchParams;
  const byBill = sp.bybill === "1";
  const r = await loadReport(sp, { title: "Settlement", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_settlement", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const s = err ? null : parseSettlement(data as unknown);
  const cut = s ? truncationNote(s.cap, "payments") : null;

  const modeHead = ["Payment mode", "Payments", "Bills", "Amount", "Rounding included"];
  const refundHead = ["Refund mode", "Refunds", "Amount"];
  const outletHead = ["Outlet", "Payments", "Collected", "Refunds", "Refunded", "Net"];
  const outlets = s ? settlementByOutlet(s) : [];
  const detailHead = ["Paid at", "Bill", "Date", "Mode", "Reference", "Received by", ...(scope.all ? ["Outlet"] : []), "Amount", "Rounding"];
  const detailText = detailHead.length - 2;
  const detailLine = (p: NonNullable<typeof s>["rows"][number]) => [
    dateTime(p.paidAt, user.timezone),
    p.billNumber || "—",
    p.businessDate,
    methodLabel(p.method),
    p.referenceNo ?? "—",
    p.receivedBy ?? "—",
    ...(scope.all ? [p.outletName] : []),
  ];

  const excel = !s
    ? null
    : s.rows.length > 0
      ? { filename: `settlement_${from}_${to}.csv`, header: detailHead, rows: csvWithFooter(
              detailHead.length,
              s.rows.map((p) => [...detailLine(p), p.amount, p.rounding]),
              [`TOTAL (${s.totals.payments} payments)`, ...Array<string>(detailText - 1).fill(""), s.totals.amount, s.totals.rounding],
              s.cap,
            ),
          }
      : s.byMode.length > 0
        ? { filename: `settlement_${from}_${to}.csv`, header: modeHead, rows: csvWithFooter(
                modeHead.length,
                s.byMode.map((m) => [methodLabel(m.method), m.payments, m.bills, m.amount, m.rounding]),
                ["TOTAL", s.totals.payments, "", s.totals.amount, s.totals.rounding],
                null,
              ),
            }
        : null;

  const nothing = !!s && s.byMode.length === 0 && s.rows.length === 0 && s.refunds.count === 0;

  return (
    <ReportShell
      ctx={ctx}
      title="Settlement"
      basePath="/reports/settlement"
      basis="payments on finished bills · refunds by the day they were given"
      landscape
      toggles={[{ name: "bybill", label: "Payment detail: one line per bill, a column for each mode", checked: byBill }]}
      excel={excel}
    >
      <div>
        {err || !s ? <Err e={err ?? { message: "Could not load the report." }} /> : nothing ? <Empty text="No payments or refunds in this period." /> : (
          <div className="space-y-6">
            <section>
              <h2 className="mb-2 text-sm font-bold">By payment mode</h2>
              <ReportTable
                head={modeHead}
                rows={s.byMode.map((m) => [methodLabel(m.method), String(m.payments), String(m.bills), money(m.amount, c), money(m.rounding, c)])}
                total={["TOTAL", String(s.totals.payments), "", money(s.totals.amount, c), money(s.totals.rounding, c)]}
              />
              <Note>Amounts include the cash rounding shown in the last column. A bill paid in two ways is counted in both modes, so the Bills column is not added up.</Note>
            </section>

            {scope.all && outlets.length > 0 && (
              <section>
                <h2 className="mb-2 text-sm font-bold">By outlet</h2>
                <ReportTable
                  head={outletHead}
                  textCols={[0]}
                  rows={outlets.map((o) => [o.outletName, String(o.payments), money(o.amount, c), String(o.refundCount), money(o.refunds, c), money(o.net, c)])}
                  total={["TOTAL", String(s?.totals.payments ?? 0), money(s?.totals.amount ?? 0, c), String(s?.refunds.count ?? 0), money(s?.totals.refunds ?? 0, c), money(s?.totals.net ?? 0, c)]}
                />
                <Note>Payments and refunds are shown for each outlet. Net is collected minus refunds.</Note>
              </section>
            )}

            <section>
              <h2 className="mb-2 text-sm font-bold">Refunds and net</h2>
              {s.refunds.count === 0 ? (
                <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No refunds were given in this period.</p>
              ) : (
                <ReportTable
                  head={refundHead}
                  rows={s.refunds.byMode.map((m) => [methodLabel(m.method), String(m.count), money(m.amount, c)])}
                  total={["TOTAL REFUNDS", String(s.refunds.count), money(s.totals.refunds, c)]}
                />
              )}
              <p className="mt-2 text-sm font-bold">
                Net collected: {money(s.totals.amount, c)} − {money(s.totals.refunds, c)} = {money(s.totals.net, c)}
              </p>
              <Note>A refund counts on the day it was given, even when the bill was paid on an earlier day.</Note>
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Payment detail</h2>
              {cut && <Note>{cut}</Note>}
              {s.rows.length === 0 ? (
                <Empty text="No payments in this period." />
              ) : byBill ? (
                <BillsByMode rows={s.rows} currency={c} showOutlet={scope.all} />
              ) : (
                <ReportTable
                  head={detailHead}
                  textCols={Array.from({ length: detailText }, (_, i) => i)}
                  zebra
                  rows={s.rows.map((p) => [...detailLine(p), money(p.amount, c), money(p.rounding, c)])}
                  total={[`TOTAL (${s.totals.payments} payments)`, ...Array<string>(detailText - 1).fill(""), money(s.totals.amount, c), money(s.totals.rounding, c)]}
                />
              )}
              <Note>The TOTAL row covers every payment in the period{cut ? ", not only the rows shown" : ""}. The Excel file holds the payment list.</Note>
            </section>
          </div>
        )}
      </div>
    </ReportShell>
  );
}
