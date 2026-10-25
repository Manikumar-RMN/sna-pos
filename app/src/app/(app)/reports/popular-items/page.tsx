import { parsePopular, reportRpcError } from "@/lib/reports-pack";
import { money } from "@/lib/format";
import { CsvButton } from "../csv-button";
import { Card, Empty, Err, Note, Table } from "../_components/ui";
import { loadReport, ReportShell } from "../_components/report-context";

const TOP = 100;

export default async function PopularItemsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Popular items" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  // Totals come from the database (best 100 items on finished bills, voided bills and cancelled lines left out).
  // The database follows the outlet picker itself, so All outlets really adds every outlet.
  const { data, error } = await supabase.rpc("report_popular_items", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const popular = err ? [] : parsePopular(data as unknown);

  return (
    <ReportShell ctx={ctx} title="Popular items" basePath="/reports/popular-items">
      <Card
        title="Items sold, most first"
        action={
          popular.length > 0 ? (
            <CsvButton
              filename={`popular_items_${from}_${to}.csv`}
              header={["Item", "Quantity", "Amount before tax"]}
              rows={popular.map((i) => [i.name, i.qty, i.amount])}
            />
          ) : null
        }
      >
        {err ? <Err e={err} /> : popular.length === 0 ? <Empty text="No items were sold in this period." /> : (
          <Table head={["Item", "Units", "Amount"]} rows={popular.map((i) => [i.name, String(i.qty), money(i.amount, c)])} />
        )}
        {popular.length >= TOP && <Note>Top {TOP} items by units sold.</Note>}
        {scope.all && <Note>Items are combined across all outlets.</Note>}
      </Card>
    </ReportShell>
  );
}
