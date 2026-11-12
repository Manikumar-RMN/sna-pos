import { reportRpcError } from "@/lib/reports-pack";
import { coversMissingNote, parseCovers, plural, type CoverRow } from "@/lib/reports-pack-3";
import { money } from "@/lib/format";
import { asList, asObj, n as num, s as str } from "@/lib/inv-report";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function CoversPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; group?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Cover analysis" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  // Guests (covers) per day, outlet and waiter come from the database: dine-in bills, finished, not merged. Money columns are only
  // filled for people who may see financial reports (the database sends null otherwise).
  const { data, error } = await supabase.rpc("report_covers", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseCovers(data as unknown);
  const t = rep?.totals;
  const showMoney = !!rep?.money;
  const m = (n: number | null) => (n === null ? "—" : money(n, c));

  const lead = (label: string) => [label];
  const cells = (x: CoverRow) => [String(x.bills), x.covers > 0 ? String(x.covers) : "—", ...(showMoney ? [m(x.sales), m(x.salesPerCover)] : [])];
  const numHead = ["Bills", "Covers", ...(showMoney ? ["Sales", "Sales per cover"] : [])];
  const totalCells = t ? [String(t.bills), String(t.covers), ...(showMoney ? [m(t.sales), m(t.salesPerCover)] : [])] : [];

  const csv: (string | number)[][] = [];
  if (rep && t) {
    const raw = (x: CoverRow) => [x.bills, x.covers, ...(showMoney ? [x.sales ?? "", x.salesPerCover ?? ""] : [])];
    for (const x of rep.byDay) csv.push(["Day", x.label, "", ...raw(x)]);
    if (scope.all) for (const x of rep.byOutlet) csv.push(["Outlet", x.label, x.outletName, ...raw(x)]);
    for (const x of rep.byWaiter) csv.push(["Waiter", x.label, x.outletName, ...raw(x)]);
    csv.push(["TOTAL", "", "", t.bills, t.covers, ...(showMoney ? [t.sales ?? "", t.salesPerCover ?? ""] : [])]);
  }
  const missing = t ? coversMissingNote(t) : "";

  // By product group: money-based, so only for people who may see financial reports.
  const byGroup = sp.group === "1" && showMoney;
  const { data: gData, error: gError } = byGroup ? await supabase.rpc("report_covers_by_group", { p_from: from, p_to: to }) : { data: null, error: null };
  const gErr = reportRpcError(gError);
  const gObj = asObj(gData);
  const gCovers = num(gObj.covers);
  const gRows = asList(gObj.rows).map((x) => ({ group: str(x.group, "No group"), units: num(x.units), amount: num(x.amount), bills: num(x.bills) }));
  const perCover = (a: number) => (gCovers > 0 ? m(Math.round((a / gCovers) * 100) / 100) : "—");

  return (
    <ReportShell
      ctx={ctx}
      title="Cover analysis"
      basePath="/reports/covers"
      basis="dine-in bills · finished, not merged · by business day"
      landscape={scope.all}
      toggles={showMoney ? [{ name: "group", label: "By product group", checked: byGroup }] : undefined}
      excel={byGroup ? (gRows.length > 0 ? { filename: `covers_by_group_${from}_${to}.csv`, header: ["Product group", "Units", "Sales", "Bills", "Sales per cover"], rows: gRows.map((x) => [x.group, x.units, x.amount, x.bills, gCovers > 0 ? Math.round((x.amount / gCovers) * 100) / 100 : ""]) } : null) : rep && rep.byDay.length > 0 ? { filename: `covers_${from}_${to}.csv`, header: ["Group", "Name", "Outlet", ...numHead], rows: csv } : null}
    >
      <div className="space-y-6">
        {byGroup ? (
          gErr ? <Err e={gErr} /> : gRows.length === 0 ? <Empty text="No dine-in bills with a guest count in this period." /> : (
            <>
              <p className="text-sm"><b>{gCovers}</b> guests on {plural(num(gObj.bills), "dine-in bill")} with a guest count.</p>
              <ReportTable
                head={["Product group", "Units", "Sales", "Bills", "Sales per cover"]}
                textCols={[0]}
                rows={gRows.map((x) => [x.group, String(x.units), m(x.amount), String(x.bills), perCover(x.amount)])}
                total={["TOTAL", String(gRows.reduce((a, x) => a + x.units, 0)), m(gRows.reduce((a, x) => a + x.amount, 0)), "", perCover(gRows.reduce((a, x) => a + x.amount, 0))]}
              />
              <Note>Sales per cover is the group&apos;s sales divided by all guests on these bills, so the groups add up to the total sales per guest. Only dine-in bills with a guest count are included. Bills with items from several groups appear in each group, so the Bills column is not added up.</Note>
            </>
          )
        ) : err ? <Err e={err} /> : !rep || !t || rep.byDay.length === 0 ? <Empty text="No dine-in bills in this period." /> : (
          <>
            <p className="text-sm">
              <b>{t.covers}</b> guests on {t.billsWithCovers} of {plural(t.bills, "bill")}{t.billsWithCovers < t.bills ? ` (${plural(t.bills - t.billsWithCovers, "bill")} without a guest count)` : ""}
              {showMoney && t.salesPerCover !== null ? <> · <b>{money(t.salesPerCover, c)}</b> sales per guest</> : null}.
            </p>

            <section>
              <h3 className="mb-2 text-sm font-bold">By day</h3>
              <ReportTable head={["Day", ...numHead]} textCols={[0]} total={["TOTAL", ...totalCells]} rows={rep.byDay.map((x) => [...lead(x.label), ...cells(x)])} />
            </section>

            {scope.all && rep.byOutlet.length > 0 && (
              <section>
                <h3 className="mb-2 text-sm font-bold">By outlet</h3>
                <ReportTable head={["Outlet", ...numHead]} textCols={[0]} total={["TOTAL", ...totalCells]} rows={rep.byOutlet.map((x) => [...lead(x.label), ...cells(x)])} />
              </section>
            )}

            <section>
              <h3 className="mb-2 text-sm font-bold">By waiter</h3>
              <ReportTable
                groupBy={scope.all ? { col: 1, sums: {} } : undefined}
                head={["Waiter", ...(scope.all ? ["Outlet"] : []), ...numHead]}
                textCols={scope.all ? [0, 1] : [0]}
                total={["TOTAL", ...(scope.all ? [""] : []), ...totalCells]}
                rows={rep.byWaiter.map((x) => [x.label, ...(scope.all ? [x.outletName] : []), ...cells(x)])}
              />
            </section>

            <Note>
              Guests are the covers entered on the bill. The waiter is shown where one was recorded; otherwise the cashier who took the bill.
              {showMoney ? " Sales per guest uses only the bills that have a guest count." : " Sales are shown only to people with the financial reports right."}
              {missing ? ` ${missing}` : ""}
              {scope.all ? " A person who worked in more than one outlet has a row for each outlet." : ""}
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
