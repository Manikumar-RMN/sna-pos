import { has } from "@/lib/auth";
import { reportRpcError } from "@/lib/reports-pack";
import { parseLoyaltyLedger, signedPoints } from "@/lib/reports-pack-4";
import { dateTime, money } from "@/lib/format";
import { Empty, Err, Note, Notice } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function LoyaltyLedgerPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  // Points are a separate add-on module; the sales-reports right is not needed here, customer.view is.
  const r = await loadReport(await searchParams, { title: "Loyalty ledger", need: "customers" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  const on = has(user, "loyalty");

  const { data, error } = on ? await supabase.rpc("report_loyalty_ledger", { p_from: from, p_to: to }) : { data: null, error: null };
  const err = reportRpcError(error);
  const rep = on && !err ? parseLoyaltyLedger(data as unknown) : null;
  const t = rep?.totals;

  const csv: (string | number)[][] = [];
  if (rep && t) {
    for (const x of rep.byDay) csv.push(["Day", x.businessDate, "", "", x.earned, x.redeemed, x.reversed, x.adjusted]);
    for (const x of rep.rows) csv.push(["Line", x.at ?? "", x.customer, x.kindText, x.points, x.billNumber ?? "", x.outlet, x.userName]);
    csv.push(["TOTAL", "", "", "", t.earned, t.redeemed, t.reversed, t.adjusted]);
  }

  return (
    <ReportShell
      ctx={ctx}
      title="Loyalty ledger"
      basePath="/reports/loyalty-ledger"
      basis="points earned, used, reversed and adjusted · by business day"
      landscape
      excel={rep && csv.length > 1 ? { filename: `loyalty_ledger_${from}_${to}.csv`, header: ["Group", "Day / Time", "Customer", "Type", "Earned / Points", "Redeemed / Bill", "Reversed / Outlet", "Adjusted / By"], rows: csv } : null}
    >
      <div className="space-y-6">
        {!on ? (
          <Empty text="Loyalty points are an add-on. Ask the owner to switch on the Loyalty module to see this report." />
        ) : err ? (
          <Err e={err} />
        ) : !rep || !t ? (
          <Empty text="Nothing to show." />
        ) : (
          <>
            <section>
              <h3 className="mb-2 text-sm font-bold">Points owed right now</h3>
              <p className="text-sm">
                <b>{rep.liability.pointsOutstanding}</b> points held by {rep.liability.customersWithPoints} customer{rep.liability.customersWithPoints === 1 ? "" : "s"}
                {rep.liability.rupeeValue !== null ? <>, worth <b>{money(rep.liability.rupeeValue, c)}</b> if all were used</> : null}.
              </p>
              <Note>This is the balance today, whatever dates are chosen above.</Note>
            </section>

            {rep.byDay.length === 0 && rep.rows.length === 0 ? (
              <Empty text="No points moved in this period." />
            ) : (
              <>
                {rep.cap.truncated && <Notice>Only the newest {rep.cap.rowLimit} lines are listed. The days and totals cover the whole period.</Notice>}

                <section>
                  <h3 className="mb-2 text-sm font-bold">By day</h3>
                  <ReportTable
                    head={["Day", "Earned", "Used", "Reversed", "Adjusted"]}
                    total={["TOTAL", String(t.earned), String(t.redeemed), String(t.reversed), String(t.adjusted)]}
                    rows={rep.byDay.map((x) => [x.businessDate, String(x.earned), String(x.redeemed), String(x.reversed), String(x.adjusted)])}
                  />
                  <p className="mt-2 text-sm">
                    Net change in the period: <b>{signedPoints(t.net)}</b> points.
                  </p>
                </section>

                <section>
                  <h3 className="mb-2 text-sm font-bold">Every line</h3>
                  <ReportTable
                    head={["Time", "Customer", "Type", "Points", "Bill", ...(scope.all ? ["Outlet"] : []), "By"]}
                    textCols={scope.all ? [0, 1, 2, 4, 5, 6] : [0, 1, 2, 4, 5]}
                    rows={rep.rows.map((x) => [
                      x.at ? dateTime(x.at, user.timezone) : "—",
                      x.customer,
                      x.kindText,
                      signedPoints(x.points),
                      x.billNumber ?? "—",
                      ...(scope.all ? [x.outlet] : []),
                      x.userName || "—",
                    ])}
                  />
                </section>

                <Note>
                  Earned is added when a bill is paid; Used is taken off when points are spent on a bill; Reversed is a voided bill or credit note
                  taking points back or returning them; Adjusted is a manual change. Lines with no bill are restaurant-wide and show as Manual.
                </Note>
              </>
            )}
          </>
        )}
      </div>
    </ReportShell>
  );
}
