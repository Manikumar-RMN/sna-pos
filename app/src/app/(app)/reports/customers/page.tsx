import { reportRpcError } from "@/lib/reports-pack";
import { captureNote, parseCustomers, pctText, ratePct } from "@/lib/reports-pack-4";
import { longDate, money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const TOP = 500;

export default async function CustomersReportPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  // Customer figures come from bills, so this needs the customer right and the sales right.
  const r = await loadReport(await searchParams, { title: "Customers", need: "customers", withSales: true });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_customers", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseCustomers(data as unknown);
  const t = rep?.totals;
  const showMoney = !!rep?.money;
  const m = (n: number | null) => (n === null ? "—" : money(n, c));
  const day = (d: string | null) => (d ? longDate(d) : "—");

  const csv: (string | number)[][] = [];
  if (rep && t) {
    for (const x of rep.byCustomer) csv.push(["Customer", x.name, x.phone, x.visits, showMoney ? (x.spend ?? "") : "", showMoney ? (x.avgBill ?? "") : "", x.firstVisitOn ?? "", x.lastVisitOn ?? "", x.isNew ? "New" : "Repeat"]);
    for (const x of rep.byDay) csv.push(["Day", x.businessDate, "", x.billsWithCustomer, showMoney ? (x.spend ?? "") : "", "", String(x.newCustomers), String(x.repeatCustomers), ""]);
  }
  const note = t ? captureNote(t) : "";

  return (
    <ReportShell
      ctx={ctx}
      title="Customers"
      basePath="/reports/customers"
      basis="finished bills with a customer attached · by business day"
      landscape
      excel={rep && csv.length > 0 ? { filename: `customers_${from}_${to}.csv`, header: ["Group", "Name / Day", "Phone", "Visits / Bills", "Spend", "Average bill", "First visit / New", "Last visit / Repeat", "Type"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || !t || (rep.byCustomer.length === 0 && rep.byDay.length === 0) ? <Empty text="No bills with a customer attached in this period." /> : (
          <>
            <p className="text-sm">
              <b>{t.customers}</b> customer{t.customers === 1 ? "" : "s"}: {t.new} new, {t.repeat} repeat
              {t.repeatRate !== null ? <> ({pctText(ratePct(t.repeatRate))} repeat)</> : null}
              {showMoney && t.spend !== null ? <> · <b>{money(t.spend, c)}</b> spent</> : null}.
            </p>
            {t.captureRate !== null && (
              <p className="text-sm">
                A customer was attached to <b>{pctText(ratePct(t.captureRate))}</b> of bills ({t.billsWithCustomer} of {t.billsTotal}).
              </p>
            )}

            <section>
              <h3 className="mb-2 text-sm font-bold">By day</h3>
              <ReportTable
                head={["Day", "Bills with a customer", "New", "Repeat", ...(showMoney ? ["Spend"] : [])]}
                total={["TOTAL", String(t.billsWithCustomer), String(t.new), String(t.repeat), ...(showMoney ? [m(t.spend)] : [])]}
                rows={rep.byDay.map((x) => [x.businessDate, String(x.billsWithCustomer), String(x.newCustomers), String(x.repeatCustomers), ...(showMoney ? [m(x.spend)] : [])])}
              />
            </section>

            <section>
              <h3 className="mb-2 text-sm font-bold">Top customers</h3>
              <ReportTable
                head={["Customer", "Phone", "Visits", ...(showMoney ? ["Spend", "Average bill"] : []), "First visit", "Last visit", "Type"]}
                textCols={[0, 1, showMoney ? 5 : 3, showMoney ? 6 : 4, showMoney ? 7 : 5]}
                rows={rep.byCustomer.map((x) => [
                  x.name,
                  x.phone || "—",
                  String(x.visits),
                  ...(showMoney ? [m(x.spend), m(x.avgBill)] : []),
                  day(x.firstVisitOn),
                  day(x.lastVisitOn),
                  x.isNew ? "New" : "Repeat",
                ])}
              />
              {rep.byCustomer.length >= TOP && <Note>Only the top {TOP} customers are listed. The totals above cover everyone.</Note>}
            </section>

            <Note>
              {note ? `${note} ` : ""}
              New means the customer's first visit was in this period. Visits and spend are counted only for the bills in this period
              {scope.all ? ", across all outlets" : ` at ${scope.label.replace(/^Outlet: /, "")}`}.
              {showMoney ? "" : " Spend is shown only to people with the financial reports right."}
              {" "}Phone numbers are private: share this page only with people who may see them.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
