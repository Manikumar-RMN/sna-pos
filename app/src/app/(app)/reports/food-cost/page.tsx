import { reportRpcError } from "@/lib/reports-pack";
import { coverageNote, dishesWithoutRecipe, parseFoodCost, pctText } from "@/lib/reports-pack-4";
import { money } from "@/lib/format";
import { Empty, Err, Note, Notice } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function FoodCostPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  // Cost against sales: needs the stock right and the sales right.
  const r = await loadReport(await searchParams, { title: "Food cost %", need: "stock", withSales: true });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_food_cost", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseFoodCost(data as unknown);
  const t = rep?.totals;
  const m = (n: number | null) => (n === null ? "—" : money(n, c));
  const missing = rep ? dishesWithoutRecipe(rep.byDish) : [];

  const csv: (string | number)[][] = [];
  if (rep && t) {
    for (const x of rep.byDay) csv.push(["Day", x.businessDate, "", "", x.netSalesCovered, x.cost, x.costPct ?? "", ""]);
    for (const x of rep.byDish) csv.push(["Dish", x.name, x.hasRecipe ? "Yes" : "No", x.qtySold, x.netSales, x.cost ?? "", x.costPct ?? "", x.margin ?? ""]);
    csv.push(["TOTAL", "", "", "", t.netSalesCovered, t.cost, t.costPct ?? "", ""]);
  }

  return (
    <ReportShell
      ctx={ctx}
      title="Food cost %"
      basePath="/reports/food-cost"
      basis="by business day · cost of the ingredients used by sales, against net sales of dishes with a recipe"
      landscape={scope.all}
      excel={rep && t && (rep.byDay.length > 0 || rep.byDish.length > 0) ? { filename: `food_cost_${from}_${to}.csv`, header: ["Group", "Name", "Has recipe", "Quantity sold", "Net sales", "Cost", "Cost %", "Margin"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || !t || (rep.byDay.length === 0 && rep.byDish.length === 0) ? <Empty text="No sales in this period." /> : (
          <>
            <p className="text-sm">
              Food cost is <b>{pctText(t.costPct)}</b> of {money(t.netSalesCovered, c)} sales
              {rep.wastageCost > 0 ? <> · wastage in the period cost <b>{money(rep.wastageCost, c)}</b> (not included in the percentage)</> : null}.
            </p>
            {coverageNote(t, missing.length) && <Notice>{coverageNote(t, missing.length)}</Notice>}

            <section>
              <h3 className="mb-2 text-sm font-bold">By day</h3>
              <ReportTable
                head={["Day", "Sales (dishes with a recipe)", "Cost", "Cost %"]}
                total={["TOTAL", m(t.netSalesCovered), m(t.cost), pctText(t.costPct)]}
                rows={rep.byDay.map((x) => [x.businessDate, m(x.netSalesCovered), m(x.cost), pctText(x.costPct)])}
              />
            </section>

            <section>
              <h3 className="mb-2 text-sm font-bold">By dish</h3>
              <ReportTable
                head={["Dish", "Sold", "Net sales", "Cost", "Cost %", "Margin"]}
                total={["TOTAL (all dishes)", "", m(t.netSalesAll), m(t.cost), pctText(t.costPct), ""]}
                rows={rep.byDish.map((x) => [
                  x.hasRecipe ? x.name : `${x.name} (no recipe)`,
                  String(Math.round(x.qtySold * 100) / 100),
                  m(x.netSales),
                  m(x.cost),
                  pctText(x.costPct),
                  m(x.margin),
                ])}
              />
            </section>

            <Note>
              Net sales are the item amounts after discount, before tax, for bills that were not voided or merged. Cost is what the recipe
              ingredients cost when the dish was sold, put back when an item is cancelled or a bill is voided. A dish with no recipe shows a dash
              and is left out of the percentage; add its recipe in Stock to include it. Margin is net sales less cost.
              {scope.all ? " This covers all outlets together." : ""}
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
