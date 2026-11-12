import { parsePopular, reportRpcError } from "@/lib/reports-pack";
import { asList, n, s as str } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { sumBy } from "@/lib/report-shell";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const TOP = 100;

export default async function PopularItemsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; session?: string; month?: string }> }) {
  const sp = await searchParams;
  const split = sp.session === "1" ? "session" : sp.month === "1" ? "month" : null;
  const r = await loadReport(sp, { title: "Popular items" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  // Totals come from the database (best 100 items on finished bills, voided bills and cancelled lines left out).
  // The database follows the outlet picker itself, so All outlets really adds every outlet.
  const { data, error } = split ? await supabase.rpc("report_popular_split", { p_from: from, p_to: to, p_by: split }) : await supabase.rpc("report_popular_items", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const popular = err || split ? [] : parsePopular(data as unknown);
  type SplitRow = { grp: string; name: string; units: number; amount: number };
  const parts: SplitRow[] = err || !split ? [] : asList(data).map((x) => ({ grp: str(x.grp, "Other"), name: str(x.name), units: n(x.units), amount: n(x.amount) }));
  const groups = [...new Set(parts.map((x) => x.grp))];
  const monthName = (g: string) => (/^\d{4}-\d{2}$/.test(g) ? new Date(`${g}-01T00:00:00Z`).toLocaleDateString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" }) : g);
  const toggles = [{ name: "session", label: "Session-wise", checked: split === "session" }, { name: "month", label: "Month-wise", checked: split === "month" }];

  return (
    <ReportShell
      ctx={ctx}
      title="Popular items"
      basePath="/reports/popular-items"
      toggles={toggles}
      excel={
        split
          ? parts.length > 0 ? { filename: `popular_items_${split}_${from}_${to}.csv`, header: [split === "session" ? "Session" : "Month", "Item", "Quantity", "Amount before tax"], rows: parts.map((i) => [monthName(i.grp), i.name, i.units, i.amount]) } : null
          : popular.length > 0
          ? { filename: `popular_items_${from}_${to}.csv`, header: ["Item", "Quantity", "Amount before tax"], rows: popular.map((i) => [i.name, i.qty, i.amount]) }
          : null
      }
    >
      <div>
        {err ? <Err e={err} /> : split ? (
          parts.length === 0 ? <Empty text="No items were sold in this period." /> : (
            <div className="space-y-5">
              {groups.map((g) => { const list = parts.filter((x) => x.grp === g); return (
                <section key={g}>
                  <h2 className="mb-2 text-sm font-bold">{split === "session" ? `Session: ${g}` : monthName(g)}</h2>
                  <ReportTable head={["Item", "Units", "Amount"]} rows={list.map((i) => [i.name, String(i.units), money(i.amount, c)])} total={["TOTAL", String(sumBy(list, (i) => i.units)), money(sumBy(list, (i) => i.amount), c)]} />
                </section>
              ); })}
              <Note>Each {split === "session" ? "session" : "month"} lists its 30 best-selling items by units. Totals are for the items shown.</Note>
            </div>
          )
        ) : popular.length === 0 ? <Empty text="No items were sold in this period." /> : (
          <ReportTable
            head={["Item", "Units", "Amount"]}
            rows={popular.map((i) => [i.name, String(i.qty), money(i.amount, c)])}
            total={[popular.length >= TOP ? `TOTAL (top ${TOP})` : "TOTAL", String(sumBy(popular, (i) => i.qty)), money(sumBy(popular, (i) => i.amount), c)]}
          />
        )}
        {popular.length >= TOP && <Note>Top {TOP} items by units sold.</Note>}
        {scope.all && <Note>Items are combined across all outlets.</Note>}
      </div>
    </ReportShell>
  );
}
