import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/** No-charge KOT detail (Winsar "NC KOT - Detail"): bills given free (complimentary or staff meal), why, and who allowed it. */
type Row = {
  id: string;
  bill_number: string | null;
  business_date: string | null;
  branch_id: string;
  comp_kind: string | null;
  comp_reason: string | null;
  comp_by: string | null;
  subtotal: number | null;
  dining_tables: { table_number: string } | null;
};
const LIMIT = 500;

export default async function NcKotPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "No-charge KOT", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;
  let q = supabase
    .from("orders")
    .select("id, bill_number, business_date, branch_id, comp_kind, comp_reason, comp_by, subtotal, dining_tables(table_number)")
    .not("comp_kind", "is", null)
    .neq("status", "voided")
    .gte("business_date", from)
    .lte("business_date", to);
  if (scope.branchId) q = q.eq("branch_id", scope.branchId);
  const { data, error } = await q.order("business_date", { ascending: false }).limit(LIMIT);
  const rows = (error ? [] : (data ?? [])) as unknown as Row[];
  const ids = [...new Set(rows.map((x) => x.comp_by).filter((x): x is string => !!x))];
  const { data: us } = ids.length ? await supabase.from("users").select("id, full_name").in("id", ids) : { data: [] as { id: string; full_name: string }[] };
  const nameOf = new Map((us ?? []).map((u) => [u.id, u.full_name]));
  const head = ["Date", "Bill", "Table", ...(scope.all ? ["Outlet"] : []), "Type", "Reason", "Allowed by", "Value given"];
  const kind = (k: string | null) => (k === "staff_meal" ? "Staff meal" : k === "complimentary" ? "Complimentary" : k ?? "—");
  const csv = rows.map((x) => [x.business_date ?? "", x.bill_number ?? "", x.dining_tables?.table_number ?? "", ...(scope.all ? [scope.names.get(x.branch_id) ?? ""] : []), kind(x.comp_kind), x.comp_reason ?? "", x.comp_by ? nameOf.get(x.comp_by) ?? "" : "", Number(x.subtotal ?? 0)]);
  const table = rows.map((x) => [x.business_date ?? "—", x.bill_number ?? "—", x.dining_tables?.table_number ?? "—", ...(scope.all ? [scope.names.get(x.branch_id) ?? "—"] : []), kind(x.comp_kind), x.comp_reason ?? "—", x.comp_by ? nameOf.get(x.comp_by) ?? "Unknown" : "—", money(Number(x.subtotal ?? 0), c)]);
  const total = rows.reduce((t, x) => t + Number(x.subtotal ?? 0), 0);
  return (
    <ReportShell
      ctx={ctx}
      title="No-charge KOT"
      basePath="/reports/nc-kot"
      basis="bills marked no-charge, by business day"
      excel={rows.length > 0 ? { filename: `nc_kot_${from}_${to}.csv`, header: head, rows: csv } : null}
    >
      {error ? <Err e={{ message: "Could not read the no-charge bills." }} /> : rows.length === 0 ? <Empty text="No bill was given free in this period." /> : (
        <ReportTable head={head} textCols={head.map((_, i) => i).filter((i) => i !== head.length - 1)} zebra rows={table} total={[...head.slice(0, -1).map((_, i) => (i === 0 ? "TOTAL" : "")), money(total, c)]} />
      )}
      <Note>"Value given" is the menu value of the items before tax, as it would have been billed. Bills that were later charged again are not listed.</Note>
    </ReportShell>
  );
}
