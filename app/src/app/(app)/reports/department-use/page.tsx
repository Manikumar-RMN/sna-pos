import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note, Notice } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function DepartmentUsePage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Use by department", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  const { data, error } = await supabase.rpc("report_department_use", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const depts = err ? [] : asList(o.departments);
  const t = asObj(o.totals);
  const head = ["Department", ...(scope.all ? ["Outlet"] : []), "Item", "Quantity", "Value"];
  const text = scope.all ? [0, 1, 2] : [0, 1];
  const cells = rows.map((x) => [s(x.department), ...(scope.all ? [s(x.outlet, "—")] : []), s(x.item), q(x.qty, x.unit), money(n(x.value), c)]);
  return (
    <ReportShell
      ctx={ctx}
      title="Use by department"
      basePath="/reports/department-use"
      basis="by issue day · stock issued to each department (cost centre) at its cost"
      excel={rows.length > 0 ? { filename: `department_use_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No stock was issued to a department in this period." /> : (
        <>
          {o.truncated === true && <Notice>Only the first {n(o.row_limit)} lines are listed. Choose a shorter period to see every line.</Notice>}
          <ReportTable head={["Department", "Value issued"]} textCols={[0]} rows={depts.map((d) => [s(d.department), money(n(d.value), c)])} total={["TOTAL", money(n(t.value), c)]} />
          <div className="h-4" />
          <ReportTable head={head} textCols={text} rows={cells} total={["TOTAL", ...head.slice(1, -1).map(() => ""), money(n(t.value), c)]} />
          <Note>Only stock issued through Material issue is counted. Value is quantity times the cost on the day of issue.</Note>
        </>
      )}
    </ReportShell>
  );
}
