import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note, Notice } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function IssuesPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Issues and department use", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_issues", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const deps = asList(o.by_department);
  const depItems = asList(o.by_department_item);
  const t = asObj(o.totals);
  const head = ["Day", "Issue", ...(scope.all ? ["Outlet"] : []), "Department", "Item", "Quantity", "Cost each", "Value"];
  const text = scope.all ? [0, 1, 2, 3, 4] : [0, 1, 2, 3];
  const cells = rows.map((x) => [s(x.issued_on), s(x.number), ...(scope.all ? [s(x.outlet, "—")] : []), s(x.department), s(x.item), q(x.qty, x.unit), money(n(x.unit_cost), c), money(n(x.value), c)]);
  return (
    <ReportShell
      ctx={ctx}
      title="Issues and department use"
      basePath="/reports/issues"
      basis="by issue day · stock handed out against requests or directly"
      landscape
      excel={rows.length > 0 ? { filename: `issues_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No stock was issued in this period." /> : (
        <div className="space-y-6">
          {o.truncated === true && <Notice>Only the newest {n(o.row_limit)} lines are listed. The department totals cover the whole period.</Notice>}
          <section>
            <h3 className="mb-2 text-sm font-bold">By department</h3>
            <ReportTable head={["Department", "Issues", "Value"]} rows={deps.map((x) => [s(x.department), String(n(x.issues)), money(n(x.value), c)])} total={["TOTAL", String(n(t.issues)), money(n(t.value), c)]} />
          </section>
          <section>
            <h3 className="mb-2 text-sm font-bold">By department and item</h3>
            <ReportTable head={["Department", "Item", "Quantity", "Value"]} textCols={[0, 1]} rows={depItems.map((x) => [s(x.department), s(x.item), q(x.qty, x.unit), money(n(x.value), c)])} />
          </section>
          <section>
            <h3 className="mb-2 text-sm font-bold">Every issue</h3>
            <ReportTable groupBy={scope.all ? { col: head.indexOf("Outlet"), sums: { [head.length - 1]: rows.map((x) => n(x.value)) }, format: (_, v) => money(v, c) } : undefined} head={head} textCols={text} rows={cells} />
          </section>
          <Note>Only stock issued here is listed. Ingredients used in dishes come off stock when the dish is billed and show in Stock movement.</Note>
        </div>
      )}
    </ReportShell>
  );
}
