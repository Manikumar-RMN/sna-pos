import { money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

type Result = {
  bills: number; covers: number; gross: number; discounts: number; service_charge: number; tax: number; rounding: number; net_total: number;
  complimentary: { count: number; value: number }; unpaid: { count: number; amount: number }; voids: { count: number; amount: number };
  cancelled_items: number; refunds: number;
  by_mode: { method: string; amount: number }[]; by_type: { type: string; bills: number; amount: number }[]; by_day: { day: string; bills: number; total: number }[];
};

const label = (t: string) => t.replace(/_/g, " ").replace(/^./, (x) => x.toUpperCase());

export default async function DaySummaryPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Day summary", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_day_summary", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const s = err ? null : (data as unknown as Result);
  const m = (n: number) => money(Number(n), c);

  const sales: [string, string][] = s
    ? [
        ["Bills", String(s.bills)],
        ["Guests (covers)", String(s.covers)],
        ["Gross sales (before discount)", m(s.gross)],
        ["Less: discounts", m(s.discounts)],
        ["Service charge", m(s.service_charge)],
        ["Tax", m(s.tax)],
        ["Rounding", m(s.rounding)],
        ["Net total", m(s.net_total)],
      ]
    : [];
  const watch: [string, string][] = s
    ? [
        ["Voided bills", `${s.voids.count} · ${m(s.voids.amount)}`],
        ["Items cancelled", String(s.cancelled_items)],
        ["Refunds given", m(s.refunds)],
        ["Complimentary / staff meals", `${s.complimentary.count} · ${m(s.complimentary.value)}`],
        ["Bills not fully paid", `${s.unpaid.count} · ${m(s.unpaid.amount)}`],
      ]
    : [];

  return (
    <ReportShell
      ctx={ctx}
      title="Day summary"
      basePath="/reports/day-summary"
      basis="finished bills by business date"
      excel={s && s.bills > 0 ? { filename: `day_summary_${from}_${to}.csv`, header: ["Item", "Value"], rows: [...sales, ...watch] } : null}
    >
      <div>
        {err || !s ? <Err e={err ?? { message: "Could not load the report." }} /> : s.bills === 0 && s.voids.count === 0 ? <Empty text="No bills in this period." /> : (
          <div className="space-y-6">
            <section>
              <h2 className="mb-2 text-sm font-bold">Sales</h2>
              <ReportTable head={["", "Value"]} textCols={[0]} rows={sales.map(([a, b]) => [a, b])} />
            </section>
            <section>
              <h2 className="mb-2 text-sm font-bold">Collected by payment mode</h2>
              {s.by_mode.length === 0 ? <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No payments.</p> : (
                <ReportTable head={["Mode", "Amount"]} textCols={[0]} rows={s.by_mode.map((x) => [x.method, m(x.amount)])} total={["TOTAL", m(s.by_mode.reduce((t, x) => t + Number(x.amount), 0))]} />
              )}
            </section>
            <section>
              <h2 className="mb-2 text-sm font-bold">By kind of bill</h2>
              <ReportTable head={["Kind", "Bills", "Amount"]} textCols={[0]} rows={s.by_type.map((x) => [label(x.type), String(x.bills), m(x.amount)])} />
            </section>
            <section>
              <h2 className="mb-2 text-sm font-bold">To watch</h2>
              <ReportTable head={["", "Count · value"]} textCols={[0, 1]} rows={watch.map(([a, b]) => [a, b])} />
            </section>
            {s.by_day.length > 1 && (
              <section>
                <h2 className="mb-2 text-sm font-bold">Day by day</h2>
                <ReportTable head={["Day", "Bills", "Total"]} textCols={[0]} rows={s.by_day.map((x) => [x.day, String(x.bills), m(x.total)])} total={["TOTAL", String(s.bills), m(s.net_total)]} />
              </section>
            )}
            <Note>Voided bills are not part of sales. Unpaid bills are counted in sales until they are voided.</Note>
          </div>
        )}
      </div>
    </ReportShell>
  );
}
