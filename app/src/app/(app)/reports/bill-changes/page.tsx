import { AUDIT_ACTION_LABEL } from "@/lib/reports-pack";
import { inChunks } from "@/lib/reports-fetch";
import { addDays, dateTime, localDayStartIso } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

/**
 * Bill changes audit (Winsar "Bill Resettlement Audit" and "KOT Audit"): who re-opened a settled bill, changed a payment mode,
 * charged a free bill again, moved a bill to another table, outlet or date, merged or split bills, or changed a kitchen ticket.
 */
const ACTIONS: Record<string, string> = {
  "order.reopen": "Settlement cancelled (bill re-opened)",
  "payment.change_mode": "Payment mode changed",
  "order.uncomplimentary": "No-charge taken off (charged again)",
  "order.date_transfer": "Bill moved to another date",
  "order.outlet_transfer": "Bill moved to another outlet",
  "order.move_table": "Bill moved to another table",
  "order.merge": "Bills merged",
  "order.split": "Bill split",
  "kot.modify": "Kitchen ticket changed",
  "order.no_tax": "Tax taken off / put back",
};
const EACH = 150;
type A = { id: number; action: string; created_at: string; user_id: string | null; branch_id: string | null; entity_id: string | null; new_value: unknown; old_value: unknown };
const rec = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const s = (v: unknown) => (typeof v === "string" ? v : typeof v === "number" ? String(v) : "");

export default async function BillChangesPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Bill changes audit", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, today, calendarToday, scope, user } = ctx;
  const tz = user.timezone;
  let q = supabase
    .from("audit_logs")
    .select("id, action, created_at, user_id, branch_id, entity_id, new_value, old_value")
    .in("action", Object.keys(ACTIONS))
    .gte("created_at", localDayStartIso(from, tz));
  // The log has no business date, so it is read by calendar date. When the range reaches the open business day or today there is no
  // upper bound, so changes made after midnight on a day that is still open are not cut off.
  if (!(to >= today || to >= calendarToday)) q = q.lt("created_at", localDayStartIso(addDays(to, 1), tz));
  if (scope.branchId) q = q.eq("branch_id", scope.branchId);
  const { data, error } = await q.order("created_at", { ascending: false }).limit(EACH * 4);
  const rows = (error ? [] : (data ?? [])) as unknown as A[];
  const uids = [...new Set(rows.map((x) => x.user_id).filter((x): x is string => !!x))];
  const oids = [...new Set(rows.filter((x) => x.entity_id && !s(rec(x.new_value).bill_number)).map((x) => x.entity_id as string))];
  const [nm, bl] = await Promise.all([
    inChunks<{ id: string; full_name: string }>(uids, (ids) => supabase.from("users").select("id, full_name").in("id", ids)),
    inChunks<{ id: string; bill_number: string }>(oids, (ids) => supabase.from("orders").select("id, bill_number").in("id", ids)),
  ]);
  const nameOf = new Map(nm.rows.map((u) => [u.id, u.full_name]));
  const billOf = new Map(bl.rows.map((o) => [o.id, o.bill_number]));
  const head = ["Time", "What happened", ...(scope.all ? ["Outlet"] : []), "Bill", "Reason / detail", "Done by"];
  const table = rows.map((x) => {
    const n = rec(x.new_value);
    const detail = [s(n.reason), s(n.business_date) && `to ${s(n.business_date)}`, s(n.outlet) && `to ${s(n.outlet)}`].filter(Boolean).join(" · ");
    return [
      dateTime(x.created_at, tz),
      ACTIONS[x.action] ?? AUDIT_ACTION_LABEL[x.action] ?? x.action,
      ...(scope.all ? [x.branch_id ? scope.names.get(x.branch_id) ?? "—" : "—"] : []),
      s(n.bill_number) || (x.entity_id ? billOf.get(x.entity_id) ?? "—" : "—"),
      detail || "—",
      x.user_id ? nameOf.get(x.user_id) ?? "Unknown" : "System",
    ];
  });
  return (
    <ReportShell
      ctx={ctx}
      title="Bill changes audit"
      basePath="/reports/bill-changes"
      basis="from the activity log, by calendar date"
      landscape
      excel={rows.length > 0 ? { filename: `bill_changes_${from}_${to}.csv`, header: head, rows: table } : null}
    >
      {error ? <Err e={{ message: "Could not read the activity log." }} /> : rows.length === 0 ? <Empty text="No bill was re-opened, moved, merged, split or re-charged in this period." /> : (
        <ReportTable head={head} textCols={head.map((_, i) => i)} zebra rows={table} />
      )}
      <Note>Voids, cancelled items and refunds are in "Voids, cancels and refunds"; reprints are in "Reprints".</Note>
    </ReportShell>
  );
}
