import { mergeCashiers, parseDiscounts, reportRpcError } from "@/lib/reports-pack";
import { longDate, money } from "@/lib/format";
import { CsvButton } from "../csv-button";
import { Card, Empty, Err, Note, Table } from "../_components/ui";
import { loadReport, ReportShell } from "../_components/report-context";

export default async function DiscountsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Discounts", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  // Discounted bills (finished, not merged, not complimentary) are summed in the database, which follows the outlet picker.
  const { data, error } = await supabase.rpc("report_discounts", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const report = parseDiscounts(err ? null : (data as unknown));
  // One row per outlet per cashier comes back; a cashier who worked in several outlets is shown once.
  const discUsers = mergeCashiers(report.byCashier);
  const discDays = report.byDay;
  const discOutlets = scope.all ? report.byOutlet : [];
  const discTotal = discUsers.reduce((s, g) => s + g.total, 0);
  const discBills = discUsers.reduce((s, g) => s + g.bills, 0);

  return (
    <ReportShell ctx={ctx} title="Discounts" basePath="/reports/discounts">
      <Card
        title="Discount summary"
        action={
          discUsers.length > 0 ? (
            <CsvButton
              filename={`discounts_${from}_${to}.csv`}
              header={["View", "Name / date", "Discounted bills", "Total discount", "Highest discount %"]}
              rows={[
                ...discOutlets.map((g) => ["By outlet", g.name, g.bills, g.total, g.maxPercent] as (string | number)[]),
                ...discUsers.map((g) => ["By cashier", g.name, g.bills, g.total, g.maxPercent] as (string | number)[]),
                ...discDays.map((g) => ["By day", g.key, g.bills, g.total, g.maxPercent] as (string | number)[]),
              ]}
            />
          ) : null
        }
      >
        {err ? <Err e={err} /> : discUsers.length === 0 ? <Empty text="No discounts were given in this period." /> : (
          <>
            <p className="mb-2 text-sm">
              {discBills} discounted bill{discBills === 1 ? "" : "s"}, {money(discTotal, c)} given away{scope.all ? " across all outlets" : ""}.
            </p>
            {scope.all && (
              <>
                <h3 className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>By outlet</h3>
                <Table
                  head={["Outlet", "Bills", "Discount", "Highest %"]}
                  rows={discOutlets.map((g) => [g.name, String(g.bills), money(g.total, c), `${g.maxPercent}%`])}
                />
              </>
            )}
            <h3 className={`${scope.all ? "mt-3 " : ""}mb-1 text-xs font-semibold`} style={{ color: "var(--color-ink-3)" }}>By cashier</h3>
            <Table
              head={["Cashier", "Bills", "Discount", "Highest %"]}
              rows={discUsers.map((g) => [g.name, String(g.bills), money(g.total, c), `${g.maxPercent}%`])}
            />
            <h3 className="mt-3 mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>By day</h3>
            <Table
              head={["Day", "Bills", "Discount", "Highest %"]}
              rows={discDays.map((g) => [longDate(g.key), String(g.bills), money(g.total, c), `${g.maxPercent}%`])}
            />
            <Note>The percentage is the discount as a share of the menu value of that bill, before tax.</Note>
          </>
        )}
      </Card>
    </ReportShell>
  );
}
