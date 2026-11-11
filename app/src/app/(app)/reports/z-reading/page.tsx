import Link from "next/link";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/**
 * Z reading (Winsar "BIR Reading Report"). Every day close already saves a full reading in business_days.z_report;
 * this screen is where it can be read and printed. It also shows the **Z number** (how many days this outlet has
 * closed) and the **accumulated grand total** (every closed day added up), which tax offices such as the BIR in the
 * Philippines ask a till to keep. Nothing is worked out again here: the figures are the ones saved at the close.
 */
type Z = {
  bills?: number;
  first_bill?: string | null;
  last_bill?: string | null;
  gross_sales?: number;
  discounts?: number;
  service_charge?: number;
  tax?: number;
  tax_included?: number;
  rounding?: number;
  total_billed?: number;
  voided_bills?: number;
  voided_value?: number;
  unpaid_bills?: number;
  payments?: { method: string; count: number; amount: number }[];
  taxes?: { component: string; rate: number; taxable: number; tax: number }[];
  credit_notes?: { count: number; amount: number; tax: number };
  order_types?: { type: string; bills: number; total: number }[];
};

type DayRow = { id: string; business_date: string; closed_at: string | null; z_report: Z | null };

export default async function ZReadingPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; day?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Z reading", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const m = (n: unknown) => money(Number(n ?? 0), c);

  // Every closed day of this outlet, oldest first: the position in this list is the Z number, and the running
  // sum of total_billed is the accumulated grand total.
  const { data: allDays, error } = await supabase
    .from("business_days")
    .select("id, business_date, closed_at, z_report")
    .eq("status", "closed")
    .order("business_date");
  const rows = (allDays ?? []) as unknown as DayRow[];

  let running = 0;
  const withTotals = rows.map((d, i) => {
    running = Math.round((running + Number(d.z_report?.total_billed ?? 0)) * 100) / 100;
    return { ...d, zNo: i + 1, accumulated: running };
  });

  const inRange = withTotals.filter((d) => d.business_date >= from && d.business_date <= to);
  const one = sp.day ? withTotals.find((d) => d.business_date === sp.day) : null;
  const z = one?.z_report ?? null;

  const listRows = inRange.map((d) => [
    String(d.zNo),
    d.business_date,
    String(d.z_report?.bills ?? 0),
    m(d.z_report?.total_billed),
    m(d.accumulated),
  ]);

  return (
    <ReportShell
      ctx={ctx}
      title={one ? `Z reading — ${one.business_date}` : "Z reading"}
      basePath="/reports/z-reading"
      basis="closed business days · the figures saved at each day close"
      excel={
        one
          ? null
          : inRange.length > 0
            ? { filename: `z_reading_${from}_${to}.csv`, header: ["Z no", "Business date", "Bills", "Total billed", "Accumulated grand total"], rows: listRows }
            : null
      }
    >
      <div>
        {error ? (
          <Err e={{ message: "Could not read the closed days." }} />
        ) : one && z ? (
          <div className="space-y-6">
            <section>
              <h2 className="mb-2 text-sm font-bold">Reading</h2>
              <ReportTable
                head={["", "Value"]}
                textCols={[0, 1]}
                rows={[
                  ["Z number", String(one.zNo)],
                  ["Business date", one.business_date],
                  ["Closed at", one.closed_at ? new Date(one.closed_at).toLocaleString() : "—"],
                  ["First bill", z.first_bill ?? "—"],
                  ["Last bill", z.last_bill ?? "—"],
                  ["Bills", String(z.bills ?? 0)],
                ]}
              />
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Sales</h2>
              <ReportTable
                head={["", "Value"]}
                textCols={[0]}
                rows={[
                  ["Gross sales (before discount)", m(z.gross_sales)],
                  ["Discounts", `− ${m(z.discounts)}`],
                  ["Service charge", m(z.service_charge)],
                  ["Tax added", m(z.tax)],
                  ["Tax already in the prices", m(z.tax_included)],
                  ["Rounding", m(z.rounding)],
                  ["TOTAL BILLED", m(z.total_billed)],
                  ["ACCUMULATED GRAND TOTAL", m(one.accumulated)],
                ]}
              />
              <Note>
                The accumulated grand total is every closed day of this outlet added up, oldest first. It only ever goes up, and it
                is the figure a tax office compares against the till.
              </Note>
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Collected by payment mode</h2>
              {(z.payments ?? []).length === 0 ? (
                <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
                  No payments on this day.
                </p>
              ) : (
                <ReportTable
                  head={["Mode", "Payments", "Amount"]}
                  textCols={[0]}
                  rows={(z.payments ?? []).map((p) => [p.method, String(p.count), m(p.amount)])}
                  total={["TOTAL", "", m((z.payments ?? []).reduce((t, p) => t + Number(p.amount), 0))]}
                />
              )}
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">Tax</h2>
              {(z.taxes ?? []).length === 0 ? (
                <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
                  No tax on this day.
                </p>
              ) : (
                <ReportTable
                  head={["Component", "Rate", "Taxable", "Tax"]}
                  textCols={[0]}
                  rows={(z.taxes ?? []).map((t) => [t.component, `${Number(t.rate)}%`, m(t.taxable), m(t.tax)])}
                  total={["TOTAL", "", "", m((z.taxes ?? []).reduce((s, t) => s + Number(t.tax), 0))]}
                />
              )}
            </section>

            <section>
              <h2 className="mb-2 text-sm font-bold">To watch</h2>
              <ReportTable
                head={["", "Count · value"]}
                textCols={[0, 1]}
                rows={[
                  ["Voided bills", `${z.voided_bills ?? 0} · ${m(z.voided_value)}`],
                  ["Bills not fully paid", String(z.unpaid_bills ?? 0)],
                  ["Credit notes", `${z.credit_notes?.count ?? 0} · ${m(z.credit_notes?.amount)}`],
                ]}
              />
            </section>

            <p className="no-print mt-4">
              <Link href="/reports/z-reading" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
                ← All closed days
              </Link>
            </p>
            <Note>
              This reading cannot be changed. It is the copy saved when the day was closed, so reopening a day or voiding a bill
              afterwards does not alter it.
            </Note>
          </div>
        ) : one && !z ? (
          <Empty text="This day was closed before readings were kept, so it has none." />
        ) : inRange.length === 0 ? (
          <Empty text="No day has been closed in this period." />
        ) : (
          <div className="space-y-3">
            <ReportTable
              head={["Z no", "Business date", "Bills", "Total billed", "Accumulated grand total"]}
              textCols={[0, 1]}
              zebra
              rows={listRows}
            />
            <div className="no-print flex flex-wrap gap-1.5">
              {inRange.map((d) => (
                <Link
                  key={d.id}
                  href={`/reports/z-reading?day=${d.business_date}&from=${from}&to=${to}&range=custom`}
                  className="rounded-md border px-2.5 py-1 text-xs font-semibold"
                  style={{ borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
                >
                  Z{d.zNo} · {d.business_date}
                </Link>
              ))}
            </div>
            <Note>Tap a day to open its reading and print it.</Note>
          </div>
        )}
      </div>
    </ReportShell>
  );
}
