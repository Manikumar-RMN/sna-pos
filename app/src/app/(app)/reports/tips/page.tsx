import { reportRpcError } from "@/lib/reports-pack";
import { parseTips, plural, type TipGroup } from "@/lib/reports-pack-3";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function TipsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Tips", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  // Tips are a memo: they are not part of sales, payments, shift cash or the day close. A tip on a voided bill is left out.
  const { data, error } = await supabase.rpc("report_tips", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseTips(data as unknown);
  const t = rep?.totals;

  const cells = (x: TipGroup) => [String(x.tips), money(x.amount, c)];
  const totalCells = t ? [String(t.tips), money(t.amount, c)] : [];

  const csv: (string | number)[][] = [];
  if (rep && t) {
    for (const x of rep.byDay) csv.push(["Day", x.label, "", x.tips, x.amount]);
    for (const x of rep.byMethod) csv.push(["Payment mode", x.label, "", x.tips, x.amount]);
    for (const x of rep.byWaiter) csv.push(["Waiter", x.label, x.outletName, x.tips, x.amount]);
    if (scope.all) for (const x of rep.byOutlet) csv.push(["Outlet", x.label, "", x.tips, x.amount]);
    csv.push(["TOTAL", "", "", t.tips, t.amount]);
  }

  return (
    <ReportShell
      ctx={ctx}
      title="Tips"
      basePath="/reports/tips"
      basis="tips recorded with the payment · by business day · not part of sales"
      excel={rep && rep.byDay.length > 0 ? { filename: `tips_${from}_${to}.csv`, header: ["Group", "Name", "Outlet", "Tips", "Amount"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || !t || rep.byDay.length === 0 ? <Empty text="No tips in this period." /> : (
          <>
            <p className="text-sm">
              <b>{money(t.amount, c)}</b> in tips on {plural(t.bills, "bill")}.
            </p>
            <section>
              <h3 className="mb-2 text-sm font-bold">By day</h3>
              <ReportTable head={["Day", "Tips", "Amount"]} textCols={[0]} total={["TOTAL", ...totalCells]} rows={rep.byDay.map((x) => [x.label, ...cells(x)])} />
            </section>
            <section>
              <h3 className="mb-2 text-sm font-bold">By payment mode</h3>
              <ReportTable head={["Payment mode", "Tips", "Amount"]} textCols={[0]} total={["TOTAL", ...totalCells]} rows={rep.byMethod.map((x) => [x.label, ...cells(x)])} />
            </section>
            <section>
              <h3 className="mb-2 text-sm font-bold">By waiter</h3>
              <ReportTable
                head={["Waiter", ...(scope.all ? ["Outlet"] : []), "Tips", "Amount"]}
                textCols={scope.all ? [0, 1] : [0]}
                total={["TOTAL", ...(scope.all ? [""] : []), ...totalCells]}
                rows={rep.byWaiter.map((x) => [x.label, ...(scope.all ? [x.outletName] : []), ...cells(x)])}
              />
            </section>
            {scope.all && rep.byOutlet.length > 0 && (
              <section>
                <h3 className="mb-2 text-sm font-bold">By outlet</h3>
                <ReportTable head={["Outlet", "Tips", "Amount"]} textCols={[0]} total={["TOTAL", ...totalCells]} rows={rep.byOutlet.map((x) => [x.label, ...cells(x)])} />
              </section>
            )}
            <Note>
              Tips are a memo only: they are not included in sales, payments, shift cash or the day close, and they are not refunded by credit notes.
              The waiter is the one recorded with the tip, otherwise the person who took it. Tips on voided bills are not counted.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
