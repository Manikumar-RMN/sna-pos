import { money } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

type Adv = { number: string; guest: string; outlet: string; status: string; kind: string; firstDate: string; received: number; receivedIn: number; adjusted: number; refunded: number; held: number; bill: string; billDate: string };

/**
 * Advances adjusted (as Winsar's "Current Advances Adjusted" and "Past Advances Adjusted"): pre-order advances applied to bills in the period,
 * split into advances taken in this same period (current) and taken earlier (past), plus advances taken in the period and still held.
 */
export default async function AdvancesPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Advances adjusted", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  const m = (x: number) => money(x, c);
  const { data, error } = await supabase.rpc("report_advances", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rows: Adv[] = err ? [] : asList(asObj(data).rows).map((x) => ({
    number: `PO-${s(String(x.number ?? ""))}`, guest: s(x.guest_name, "—"), outlet: s(x.outlet_name), status: s(x.status), kind: s(x.period_kind, "Other"),
    firstDate: s(x.first_date, "—"), received: n(x.received), receivedIn: n(x.received_in_period), adjusted: n(x.adjusted), refunded: n(x.refunded), held: n(x.held), bill: s(x.bill_number, "—"), billDate: s(x.adjusted_date, "—"),
  }));

  const head = ["Pre-order", "Guest", ...(scope.all ? ["Outlet"] : []), "Advance taken on", "Advance taken", "Adjusted on bill", "Bill date", "Adjusted", "Refunded", "Still held"];
  const text = [0, 1, ...(scope.all ? [2] : []), scope.all ? 3 : 2, scope.all ? 5 : 4, scope.all ? 6 : 5];
  const line = (a: Adv) => [a.number, a.guest, ...(scope.all ? [a.outlet] : []), a.firstDate, m(a.received), a.bill, a.billDate, m(a.adjusted), m(a.refunded), m(a.held)];
  const sum = (list: Adv[], f: (a: Adv) => number) => list.reduce((x, a) => x + f(a), 0);
  const total = (label: string, list: Adv[]) => [`${label} (${list.length})`, "", ...(scope.all ? [""] : []), "", m(sum(list, (a) => a.received)), "", "", m(sum(list, (a) => a.adjusted)), m(sum(list, (a) => a.refunded)), m(sum(list, (a) => a.held))];
  const sections: { key: string; title: string; note: string }[] = [
    { key: "Current", title: "Current advances adjusted", note: "Advance taken and applied to a bill within this period." },
    { key: "Past", title: "Past advances adjusted", note: "Advance taken before this period and applied to a bill within it." },
    { key: "Held", title: "Advances taken, not yet applied", note: "Advance taken in this period; the pre-order has not been billed yet, so the money is still held." },
  ];
  const csvHead = ["Section", ...head];
  const csvRows = rows.map((a) => [a.kind, a.number, a.guest, ...(scope.all ? [a.outlet] : []), a.firstDate, a.received, a.bill, a.billDate, a.adjusted, a.refunded, a.held]);

  return (
    <ReportShell
      ctx={ctx}
      title="Advances adjusted"
      basePath="/reports/advances"
      basis="pre-order advances · by the day taken and the day of the bill"
      landscape
      excel={rows.length > 0 ? { filename: `advances_${from}_${to}.csv`, header: csvHead, rows: csvRows } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No advances were taken or applied in this period." /> : (
        <div className="space-y-6">
          {sections.map((sec) => {
            const list = rows.filter((a) => a.kind === sec.key);
            return (
              <section key={sec.key}>
                <h2 className="mb-1 text-sm font-bold">{sec.title}</h2>
                <p className="mb-2 text-xs" style={{ color: "var(--color-ink-3)" }}>{sec.note}</p>
                {list.length === 0 ? <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>None in this period.</p> : (
                  <ReportTable head={head} textCols={text} zebra rows={list.map(line)} total={total("TOTAL", list)} />
                )}
              </section>
            );
          })}
          <Note>&quot;Still held&quot; is the advance money the restaurant holds for that pre-order after refunds and after what was applied to the bill. If an advance is more than the bill, the extra is handed back and shows under Refunded. Check with your accountant how advances are shown in the GST return.</Note>
        </div>
      )}
    </ReportShell>
  );
}
