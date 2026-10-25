import { AUDIT_ACTION_LABEL, auditDetail } from "@/lib/reports-pack";
import { inChunks } from "@/lib/reports-fetch";
import { friendlyDbError } from "@/lib/db-error";
import { addDays, dateTime, localDayStartIso, money } from "@/lib/format";
import { CsvButton } from "../csv-button";
import { Card, Empty, Err, Note, Notice, Table } from "../_components/ui";
import { loadReport, ReportShell } from "../_components/report-context";

const AUDIT_EACH = 100;
const AUDIT_ADJUST_FETCH = 300;
/** Audit actions listed. Manager-PIN approvals are left out: they are written on every approval and would bury the rest. */
const AUDIT_HIGH = ["order.void", "order.cancel_item", "kot.cancel", "order.refund", "credit_note.issue", "order.complimentary"] as const;

type AuditRow = {
  id: number;
  action: string;
  created_at: string;
  user_id: string | null;
  branch_id: string | null;
  entity_type: string;
  entity_id: string | null;
  new_value: unknown;
  old_value: unknown;
};

export default async function AuditPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Voids, cancels and refunds", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, today, calendarToday, scope, user } = ctx;
  const c = user.currency_code;
  const tz = user.timezone;

  // The activity log has no business date, so it is read by calendar date. When the range reaches today (or the open
  // business day, which can run past midnight) there is no upper bound, so late entries are not cut off.
  const openEnded = to >= today || to >= calendarToday;
  const auditFrom = localDayStartIso(from, tz);
  const auditTo = localDayStartIso(addDays(to, 1), tz);
  const auditCols = "id, action, created_at, user_id, branch_id, entity_type, entity_id, new_value, old_value";
  // The activity log is not narrowed to one outlet by the database, so the chosen outlet is applied here.
  const auditFor = (action: string, limit: number) => {
    let q = supabase.from("audit_logs").select(auditCols).eq("action", action).gte("created_at", auditFrom);
    if (scope.branchId) q = q.eq("branch_id", scope.branchId);
    if (!openEnded) q = q.lt("created_at", auditTo);
    return q.order("created_at", { ascending: false }).limit(limit);
  };
  const auditR = await Promise.all([...AUDIT_HIGH.map((a) => auditFor(a, AUDIT_EACH)), auditFor("order.adjust", AUDIT_ADJUST_FETCH)]);

  const auditError = auditR.map((x) => x.error).find((e) => !!e) ?? null;
  const auditGroups = auditR.map((x) => (x.data ?? []) as unknown as AuditRow[]);
  const auditHitLimit = auditGroups.slice(0, AUDIT_HIGH.length).some((g) => g.length >= AUDIT_EACH);
  const adjustRows = (auditGroups[AUDIT_HIGH.length] ?? [])
    .filter((x) => auditDetail(x.action, x.new_value, x.old_value).amount)
    .slice(0, AUDIT_EACH);
  const auditRows: AuditRow[] = [...auditGroups.slice(0, AUDIT_HIGH.length).flat(), ...adjustRows].sort((x, y) =>
    y.created_at.localeCompare(x.created_at),
  );

  const userIds = new Set<string>();
  for (const x of auditRows) if (x.user_id) userIds.add(x.user_id);
  const voidIds = auditRows
    .filter((x) => x.entity_type === "orders" && x.entity_id && !(x.new_value as { bill_number?: string } | null)?.bill_number)
    .map((x) => x.entity_id as string);
  const [namesR, billsR] = await Promise.all([
    inChunks<{ id: string; full_name: string }>([...userIds], (ids) => supabase.from("users").select("id, full_name").in("id", ids)),
    inChunks<{ id: string; bill_number: string }>([...new Set(voidIds)], (ids) => supabase.from("orders").select("id, bill_number").in("id", ids)),
  ]);
  const lookupError = namesR.error ?? billsR.error;
  const nameOf = new Map(namesR.rows.map((u) => [u.id, u.full_name]));
  const billOf = new Map(billsR.rows.map((o) => [o.id, o.bill_number]));
  const who = (id: string | null | undefined) => (id ? nameOf.get(id) ?? "Unknown" : "System");
  const outletName = (id: string | null) => (id ? scope.names.get(id) ?? "Unknown outlet" : "—");

  const head = ["Time", "What happened", ...(scope.all ? ["Outlet"] : []), "Bill", "Details", "Amount", "Reason", "Done by"];
  const csvRows = auditRows.map((x) => {
    const d = auditDetail(x.action, x.new_value, x.old_value);
    return [
      dateTime(x.created_at, tz),
      AUDIT_ACTION_LABEL[x.action] ?? x.action,
      ...(scope.all ? [outletName(x.branch_id)] : []),
      d.bill || (x.entity_id ? billOf.get(x.entity_id) ?? "" : ""),
      d.detail,
      d.amount ?? "",
      d.reason,
      who(x.user_id),
    ];
  });
  const tableRows = auditRows.map((x) => {
    const d = auditDetail(x.action, x.new_value, x.old_value);
    return [
      dateTime(x.created_at, tz),
      AUDIT_ACTION_LABEL[x.action] ?? x.action,
      ...(scope.all ? [outletName(x.branch_id)] : []),
      d.bill || (x.entity_id ? billOf.get(x.entity_id) ?? "—" : "—"),
      d.detail || "—",
      d.amount == null ? "—" : money(d.amount, c),
      d.reason || "—",
      who(x.user_id),
    ];
  });
  // Text columns (left-aligned): time, what happened, outlet, bill, details, reason, done by.
  const amountCol = head.indexOf("Amount");
  const textCols = head.map((_, i) => i).filter((i) => i !== amountCol);

  return (
    <ReportShell ctx={ctx} title="Voids, cancels and refunds" basePath="/reports/audit" basis="from the activity log, by calendar date">
      {lookupError && (
        <Notice tone="bad">
          Some staff names or bill numbers could not be loaded ({friendlyDbError(lookupError)}). They may show as Unknown or blank.
        </Notice>
      )}
      <Card
        title="Voids, cancels, refunds and discount approvals"
        action={
          auditRows.length > 0 ? <CsvButton filename={`audit_${from}_${to}.csv`} header={head} rows={csvRows} /> : null
        }
      >
        {auditError ? <Err e={auditError} /> : auditRows.length === 0 ? <Empty text="Nothing was voided, cancelled or refunded in this period." /> : (
          <>
            <Table head={head} rows={tableRows} textCols={textCols} />
            {auditHitLimit && <Note>Showing the latest {AUDIT_EACH} of each kind. Choose a shorter range to see older entries.</Note>}
          </>
        )}
        <Note>
          From the activity log, by calendar date and for {scope.all ? "all outlets" : "this outlet"}. Manager PIN approvals and bill adjustments with no discount are not listed. Reprints of bills are not recorded in the activity log, so they cannot be listed here.
        </Note>
      </Card>
    </ReportShell>
  );
}
