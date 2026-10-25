import { parseUnsold, reportRpcError } from "@/lib/reports-pack";
import { money } from "@/lib/format";
import { sumBy } from "@/lib/report-shell";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const TOP = 100;

export default async function SlowItemsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Slow and unsold items" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  // The database works out which items are active (on the menu, available, not a size parent, not switched off at the
  // chosen outlet; for All outlets only items switched off everywhere are left out) and which of them sold.
  const { data, error } = await supabase.rpc("report_unsold_items", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const { dead, slow } = err ? { dead: [], slow: [] } : parseUnsold(data as unknown);

  return (
    <ReportShell
      ctx={ctx}
      title="Slow and unsold items"
      basePath="/reports/slow-items"
      excel={
        slow.length + dead.length > 0
          ? {
              filename: `slow_items_${from}_${to}.csv`,
              header: ["Item", "Status", "Quantity", "Amount before tax"],
              rows: [
                ...dead.map((d) => [d.name, "No sales", 0, 0] as (string | number)[]),
                ...slow.map((s) => [s.name, "Slow", s.qty, s.amount] as (string | number)[]),
              ],
            }
          : null
      }
    >
      <div>
        {err ? <Err e={err} /> : dead.length + slow.length === 0 ? (
          <Empty text="There are no active menu items." />
        ) : (
          <>
            <h3 className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Not sold at all ({dead.length})
            </h3>
            {dead.length === 0 ? (
              <p className="mb-3 text-sm" style={{ color: "var(--color-ink-3)" }}>Every active item sold at least once.</p>
            ) : (
              <div className="mb-3">
                <ReportTable head={["Item"]} rows={dead.slice(0, TOP).map((d) => [d.name])} />
                {dead.length > TOP && <Note>Showing {TOP} of {dead.length}. The CSV has them all.</Note>}
              </div>
            )}
            <h3 className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Sold least ({slow.length})
            </h3>
            {slow.length === 0 ? <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>Nothing to show.</p> : (
              <ReportTable
                head={["Item", "Units", "Amount"]}
                rows={slow.map((s) => [s.name, String(s.qty), money(s.amount, c)])}
                total={["TOTAL", String(sumBy(slow, (s) => s.qty)), money(sumBy(slow, (s) => s.amount), c)]}
              />
            )}
            <Note>
              Only items that are on the menu and available are counted.
              {scope.all
                ? " Sales of all outlets are added together, and an item counts as sold if any outlet sold it. Items switched off in every outlet are left out."
                : " Items switched off at this outlet are left out."}
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
