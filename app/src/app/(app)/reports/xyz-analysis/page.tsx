import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function XyzPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; days?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "XYZ analysis", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const days = Math.min(364, Math.max(28, Number(sp.days) || 84));
  const { data, error } = await ctx.supabase.rpc("report_xyz", { p_days: days });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head = ["Item", "Used in total", "Average a week", "Variation", "Class"];
  const cells = rows.map((x) => [s(x.name), q(x.total, x.unit), q(x.avg_week, x.unit), x.cv == null ? "—" : String(n(x.cv)), s(x.class)]);
  return (
    <ReportShell
      ctx={ctx}
      title="XYZ analysis"
      basePath="/reports/xyz-analysis"
      basis={`weekly use over the last ${n(o.weeks) || Math.floor(days / 7)} weeks · how steady the demand is`}
      excel={rows.length > 0 ? { filename: `xyz_analysis.csv`, header: head, rows: cells } : null}
    >
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No ingredient was used in this period." /> : (
        <>
          <ReportTable head={head} textCols={[0, 4]} rows={cells} total={["TOTAL", "", "", "", `X ${n(t.x)} · Y ${n(t.y)} · Z ${n(t.z)}`]} />
          <Note>
            Variation is how much weekly use moves around its average (0 means exactly the same every week). X is steady (up to 0.5): order on a fixed schedule. Y is moderate (up to 1). Z is erratic (above 1): keep a safety margin or buy as needed. Use counts sales, wastage, transfers out and issues. Add ?days=180 to the address to look further back (28 to 364 days).
          </Note>
        </>
      )}
    </ReportShell>
  );
}
