import { reportRpcError } from "@/lib/reports-pack";
import { movementKindLabel, parseStockMovement, qtyText } from "@/lib/reports-pack-4";
import { dateTime, money } from "@/lib/format";
import { Empty, Err, Note, Notice } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function StockMovementPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Stock movement", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_stock_movement", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseStockMovement(data as unknown);
  const m = (n: number | null) => (n === null ? "—" : money(n, c));

  const sumHead = [...(scope.all ? ["Outlet"] : []), "Ingredient", "Opening", "Bought", "Transfer in", "Transfer out", "Used", "Wasted", "Adjusted", "Counted", "Closing"];
  const sumText = scope.all ? [0, 1] : [0];
  const detHead = ["Day", "Time", ...(scope.all ? ["Outlet"] : []), "Ingredient", "Type", "Quantity", "Cost per unit", "Value", "Bill", "Reason / note", "By"];
  const detText = scope.all ? [0, 1, 2, 3, 4, 8, 9, 10] : [0, 1, 2, 3, 7, 8, 9];

  const csv: (string | number)[][] = [];
  if (rep) {
    for (const x of rep.summary) csv.push(["Summary", "", ...(scope.all ? [x.outletName] : []), x.name, "", x.unit, x.opening, x.purchased, x.transferIn, x.transferOut, x.used, x.wasted, x.adjusted, x.counted, x.closing]);
    for (const x of rep.rows) csv.push(["Line", x.businessDate, ...(scope.all ? [x.outletName] : []), x.ingredient, movementKindLabel(x.kind), x.unit, x.qty, x.unitCost ?? "", x.value ?? "", x.billNumber ?? "", [x.reason, x.note].filter(Boolean).join(" - "), x.userName]);
  }

  return (
    <ReportShell
      ctx={ctx}
      title="Stock movement"
      basePath="/reports/stock-movement"
      basis="by business day · every change to stock, per outlet"
      landscape
      excel={rep && csv.length > 0 ? { filename: `stock_movement_${from}_${to}.csv`, header: ["Part", "Day", ...(scope.all ? ["Outlet"] : []), "Ingredient", "Type", "Unit", "Opening / Quantity", "Bought / Cost per unit", "Transfer in / Value", "Transfer out / Bill", "Used / Reason", "Wasted / By", "Adjusted", "Counted", "Closing"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || (rep.summary.length === 0 && rep.rows.length === 0) ? <Empty text="No stock movements in this period." /> : (
          <>
            {rep.cap.truncated && <Notice>Only the newest {rep.cap.rowLimit} lines are listed. The summary above them covers the whole period; choose a shorter period to see every line.</Notice>}

            <section>
              <h3 className="mb-2 text-sm font-bold">By ingredient</h3>
              <ReportTable
                head={sumHead}
                textCols={sumText}
                rows={rep.summary.map((x) => [
                  ...(scope.all ? [x.outletName] : []),
                  x.name,
                  qtyText(x.opening, x.unit),
                  qtyText(x.purchased, x.unit),
                  qtyText(x.transferIn, x.unit),
                  qtyText(x.transferOut, x.unit),
                  qtyText(x.used, x.unit),
                  qtyText(x.wasted, x.unit),
                  qtyText(x.adjusted, x.unit),
                  qtyText(x.counted, x.unit),
                  <b key="c" style={x.closing < 0 ? { color: "var(--color-bad)" } : undefined}>{qtyText(x.closing, x.unit)}</b>,
                ])}
              />
            </section>

            <section>
              <h3 className="mb-2 text-sm font-bold">Every line</h3>
              <ReportTable
                head={detHead}
                textCols={detText}
                rows={rep.rows.map((x) => [
                  x.businessDate,
                  x.at ? dateTime(x.at, user.timezone) : "—",
                  ...(scope.all ? [x.outletName || "—"] : []),
                  x.ingredient,
                  movementKindLabel(x.kind),
                  qtyText(x.qty, x.unit),
                  m(x.unitCost),
                  m(x.value),
                  x.billNumber ?? "—",
                  [x.reason, x.note].filter(Boolean).join(" - ") || "—",
                  x.userName || "—",
                ])}
              />
            </section>

            <section>
              <h3 className="mb-2 text-sm font-bold">Value of the movements ({rep.totals.movements} in the period)</h3>
              <ReportTable
                head={["Bought", "Used in sales", "Wasted", "Adjusted", "Counted"]}
                rows={[[m(rep.totals.purchasedValue), m(rep.totals.usedValue), m(rep.totals.wastedValue), m(rep.totals.adjustedValue), m(rep.totals.countedValue)]]}
              />
            </section>

            <Note>
              Opening is the stock at the start of the first day; closing is what is left at the end of the last day. Used is stock taken by
              sales less what came back from cancelled items and voided bills. Counted is the difference a stock count found.
              A plus is stock added, a minus is stock taken out. Value is the quantity times the cost when the movement happened.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
