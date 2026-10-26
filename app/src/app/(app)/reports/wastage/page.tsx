import { reportRpcError } from "@/lib/reports-pack";
import { parseWastage, qtyText, type WastageGroup } from "@/lib/reports-pack-4";
import { dateTime, money } from "@/lib/format";
import { Empty, Err, Note, Notice } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function WastagePage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Wastage", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_wastage", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseWastage(data as unknown);
  const t = rep?.totals;
  const m = (n: number | null) => (n === null ? "—" : money(n, c));

  const group = (title: string, label: string, gs: WastageGroup[]) =>
    gs.length === 0 ? null : (
      <section>
        <h3 className="mb-2 text-sm font-bold">{title}</h3>
        <ReportTable head={[label, "Lines", "Value"]} total={["TOTAL", String(t?.lines ?? 0), m(t?.value ?? 0)]} rows={gs.map((x) => [x.label, String(x.lines), m(x.value)])} />
      </section>
    );

  const csv: (string | number)[][] = [];
  if (rep && t) {
    for (const x of rep.byReason) csv.push(["Reason", x.label, "", "", x.lines, x.value, ""]);
    for (const x of rep.byIngredient) csv.push(["Ingredient", x.label, "", x.unit, x.lines, x.value, x.qty ?? ""]);
    for (const x of rep.byDay) csv.push(["Day", x.label, "", "", x.lines, x.value, ""]);
    for (const x of rep.byUser) csv.push(["Person", x.label, "", "", x.lines, x.value, ""]);
    for (const x of rep.rows) csv.push(["Line", x.businessDate, x.ingredient, x.unit, x.qty, x.value ?? "", [x.reason, x.note].filter(Boolean).join(" - ")]);
    csv.push(["TOTAL", "", "", "", t.lines, t.value, ""]);
  }

  return (
    <ReportShell
      ctx={ctx}
      title="Wastage"
      basePath="/reports/wastage"
      basis="by business day · stock recorded as wastage (adjustments are in Stock movement)"
      landscape
      excel={rep && csv.length > 1 ? { filename: `wastage_${from}_${to}.csv`, header: ["Group", "Name", "Ingredient", "Unit", "Lines / Quantity", "Value", "Quantity / Reason"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || !t || (rep.rows.length === 0 && t.lines === 0) ? <Empty text="No wastage was recorded in this period." /> : (
          <>
            <p className="text-sm">
              <b>{m(t.value)}</b> of stock was wasted in {t.lines} line{t.lines === 1 ? "" : "s"}.
            </p>
            {rep.cap.truncated && <Notice>Only the newest {rep.cap.rowLimit} lines are listed. The groups above them cover the whole period.</Notice>}

            {group("By reason", "Reason", rep.byReason)}

            {rep.byIngredient.length > 0 && (
              <section>
                <h3 className="mb-2 text-sm font-bold">By ingredient</h3>
                <ReportTable
                  head={["Ingredient", "Lines", "Quantity", "Value"]}
                  total={["TOTAL", String(t.lines), "", m(t.value)]}
                  rows={rep.byIngredient.map((x) => [x.label, String(x.lines), x.qty === null ? "—" : qtyText(x.qty, x.unit), m(x.value)])}
                />
              </section>
            )}

            {group("By day", "Day", rep.byDay)}
            {group("By person", "Recorded by", rep.byUser)}

            <section>
              <h3 className="mb-2 text-sm font-bold">Every line</h3>
              <ReportTable
                head={["Day", "Time", ...(scope.all ? ["Outlet"] : []), "Ingredient", "Quantity", "Value", "Reason", "Note", "By"]}
                textCols={scope.all ? [0, 1, 2, 3, 6, 7, 8] : [0, 1, 2, 5, 6, 7]}
                rows={rep.rows.map((x) => [
                  x.businessDate,
                  x.at ? dateTime(x.at, user.timezone) : "—",
                  ...(scope.all ? [x.outletName || "—"] : []),
                  x.ingredient,
                  qtyText(x.qty, x.unit),
                  m(x.value),
                  x.reason,
                  x.note || "—",
                  x.userName || "—",
                ])}
              />
            </section>

            <Note>Value is the quantity times the cost per unit when the wastage was recorded.</Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
