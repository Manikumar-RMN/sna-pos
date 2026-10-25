import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError, type DbErrorLike } from "@/lib/db-error";
import { addDays, dateTime, isYmd, localDayStartIso, longDate, money, todayIn } from "@/lib/format";
import {
  AUDIT_ACTION_LABEL,
  aggregateItems,
  aggregateWaiters,
  auditDetail,
  discountsByDay,
  discountsByUser,
  resolveRange,
  splitPopularSlow,
  type ItemLine,
  type OrderRow,
} from "@/lib/reports-pack";
import { CsvButton } from "../csv-button";

/** Rows fetched per request, and the most rows one report will read. */
const PAGE = 1000;
const MAX_ROWS = 50000;
const TOP = 100;
const AUDIT_EACH = 100;
const AUDIT_ADJUST_FETCH = 300;
/** Audit actions listed. Manager-PIN approvals are left out: they are written on every approval and would bury the rest. */
const AUDIT_HIGH = ["order.void", "order.cancel_item", "kot.cancel", "order.refund", "credit_note.issue", "order.complimentary"] as const;
const IN_CHUNK = 100;

type Paged = PromiseLike<{ data: unknown[] | null; error: DbErrorLike | null }>;

/** Reads every page of a query (the database returns at most 1000 rows at a time). */
async function fetchAll<T>(page: (a: number, b: number) => Paged): Promise<{ rows: T[]; error: DbErrorLike | null; truncated: boolean }> {
  const rows: T[] = [];
  for (let a = 0; a < MAX_ROWS; a += PAGE) {
    const { data, error } = await page(a, a + PAGE - 1);
    if (error) return { rows, error, truncated: false };
    const got = (data ?? []) as T[];
    rows.push(...got);
    if (got.length < PAGE) return { rows, error: null, truncated: false };
  }
  return { rows, error: null, truncated: true };
}

/** Looks up rows by id in small groups (a long list of ids in one request can be refused as too long). */
async function inChunks<T>(
  ids: string[],
  run: (chunk: string[]) => PromiseLike<{ data: T[] | null; error: DbErrorLike | null }>,
): Promise<{ rows: T[]; error: DbErrorLike | null }> {
  const rows: T[] = [];
  for (let i = 0; i < ids.length; i += IN_CHUNK) {
    const { data, error } = await run(ids.slice(i, i + IN_CHUNK));
    if (error) return { rows, error };
    rows.push(...(data ?? []));
  }
  return { rows, error: null };
}

type ProductRow = { id: string; name: string; parent_id: string | null };
type AuditRow = {
  id: number;
  action: string;
  created_at: string;
  user_id: string | null;
  entity_type: string;
  entity_id: string | null;
  new_value: unknown;
  old_value: unknown;
};

export default async function MoreReportsPage({
  searchParams,
}: {
  searchParams: Promise<{ range?: string; from?: string; to?: string }>;
}) {
  const user = await requireUser();
  const canSales = can(user, "report.view_sales");
  const canFinancial = can(user, "report.view_financial");
  if (!canSales) {
    return (
      <div className="mx-auto max-w-md">
        <h1 className="text-xl font-bold tracking-tight">More reports</h1>
        <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Your role does not include viewing sales reports.
        </div>
      </div>
    );
  }

  const sp = await searchParams;
  const supabase = await createClient();
  // Same business day logic as the main Reports page.
  const { data: latestDay } = await supabase
    .from("business_days")
    .select("business_date, status")
    .order("business_date", { ascending: false })
    .limit(1)
    .maybeSingle();
  const calendarToday = todayIn(user.timezone);
  const today = latestDay?.business_date && isYmd(latestDay.business_date)
    && (latestDay.status === "open" || latestDay.business_date > calendarToday)
    ? latestDay.business_date
    : calendarToday;
  const { from, to, range } = resolveRange(today, sp);
  const multi = has(user, "multi_outlet") && user.outlet_count > 1;
  const c = user.currency_code;
  const tz = user.timezone;

  // Bills of the range: finished (not voided), not merged into another bill, by business day.
  const ordersQ = fetchAll<OrderRow>((a, b) =>
    supabase
      .from("orders")
      .select("business_date, cashier_id, waiter_id, covers, grand_total, subtotal, discount_total")
      .eq("status", "completed")
      .is("merged_into", null)
      .is("comp_kind", null)
      .gte("business_date", from)
      .lte("business_date", to)
      .order("id")
      .range(a, b),
  );
  // Items on those bills, leaving out voided bills and cancelled lines (same rule as "Items sold").
  const itemsQ = fetchAll<ItemLine>((a, b) =>
    supabase
      .from("order_items")
      .select("id, product_id, product_name, quantity, line_subtotal, orders!inner(status, business_date, merged_into)")
      .is("cancelled_at", null)
      .eq("orders.status", "completed")
      .is("orders.merged_into", null)
      .gte("orders.business_date", from)
      .lte("orders.business_date", to)
      .order("id")
      .range(a, b),
  );
  const productsQ = fetchAll<ProductRow>((a, b) =>
    supabase
      .from("products")
      .select("id, name, parent_id")
      .is("deleted_at", null)
      .eq("is_available", true)
      .eq("is_charge", false)
      .order("id")
      .range(a, b),
  );
  // The activity log has no business date, so it is read by calendar date. When the range reaches today (or the open
  // business day, which can run past midnight) there is no upper bound, so late entries are not cut off.
  const openEnded = to >= today || to >= calendarToday;
  const auditFrom = localDayStartIso(from, tz);
  const auditTo = localDayStartIso(addDays(to, 1), tz);
  const auditCols = "id, action, created_at, user_id, entity_type, entity_id, new_value, old_value";
  const auditFor = (action: string, limit: number) => {
    let q = supabase
      .from("audit_logs")
      .select(auditCols)
      .eq("action", action)
      .eq("branch_id", user.branch_id)
      .gte("created_at", auditFrom);
    if (!openEnded) q = q.lt("created_at", auditTo);
    return q.order("created_at", { ascending: false }).limit(limit);
  };
  const auditQ = canFinancial
    ? Promise.all([...AUDIT_HIGH.map((a) => auditFor(a, AUDIT_EACH)), auditFor("order.adjust", AUDIT_ADJUST_FETCH)])
    : Promise.resolve(null);
  // Items switched off at this outlet are not "unsold", they are not on its menu.
  const offHereQ = fetchAll<{ product_id: string }>((a, b) =>
    supabase
      .from("branch_prices")
      .select("product_id")
      .eq("branch_id", user.branch_id)
      .eq("is_available", false)
      .order("product_id")
      .range(a, b),
  );
  const outletsQ = multi ? supabase.rpc("my_outlets") : Promise.resolve({ data: null });

  const [ordersR, itemsR, productsR, auditR, offHereR, outletsR] = await Promise.all([ordersQ, itemsQ, productsQ, auditQ, offHereQ, outletsQ]);
  const orders = ordersR.rows;
  const allOutlets = !!(outletsR.data as unknown as { all_outlets?: boolean } | null)?.all_outlets;
  const auditError = auditR ? auditR.map((r) => r.error).find((e) => !!e) ?? null : null;
  const auditGroups = (auditR ?? []).map((r) => (r.data ?? []) as unknown as AuditRow[]);
  const auditHitLimit = auditGroups.slice(0, AUDIT_HIGH.length).some((g) => g.length >= AUDIT_EACH);
  const adjustRows = (auditGroups[AUDIT_HIGH.length] ?? [])
    .filter((r) => auditDetail(r.action, r.new_value, r.old_value).amount)
    .slice(0, AUDIT_EACH);
  const auditRows: AuditRow[] = [...auditGroups.slice(0, AUDIT_HIGH.length).flat(), ...adjustRows].sort((x, y) =>
    y.created_at.localeCompare(x.created_at),
  );

  // Names for the people and bills that appear.
  const userIds = new Set<string>();
  for (const o of orders) {
    if (o.waiter_id ?? o.cashier_id) userIds.add((o.waiter_id ?? o.cashier_id) as string);
    if (o.cashier_id) userIds.add(o.cashier_id);
  }
  for (const r of auditRows) if (r.user_id) userIds.add(r.user_id);
  const voidIds = auditRows
    .filter((r) => r.entity_type === "orders" && r.entity_id && !(r.new_value as { bill_number?: string } | null)?.bill_number)
    .map((r) => r.entity_id as string);
  const [namesR, billsR] = await Promise.all([
    inChunks<{ id: string; full_name: string }>([...userIds], (ids) => supabase.from("users").select("id, full_name").in("id", ids)),
    inChunks<{ id: string; bill_number: string }>([...new Set(voidIds)], (ids) => supabase.from("orders").select("id, bill_number").in("id", ids)),
  ]);
  const lookupError = namesR.error ?? billsR.error;
  const nameOf = new Map(namesR.rows.map((u) => [u.id, u.full_name]));
  const billOf = new Map(billsR.rows.map((o) => [o.id, o.bill_number]));
  const who = (id: string | null | undefined) => (id ? nameOf.get(id) ?? "Unknown" : "System");

  // 1. Popular and slow items
  const sold = aggregateItems(itemsR.rows);
  const parents = new Set(productsR.rows.map((p) => p.parent_id).filter((x): x is string => !!x));
  const offHere = new Set(offHereR.rows.map((r) => r.product_id));
  const active = productsR.rows.filter((p) => !parents.has(p.id) && !offHere.has(p.id)).map((p) => ({ id: p.id, name: p.name }));
  const { popular, slow, dead } = splitPopularSlow(sold, active, { top: TOP });

  // 2. Waiters
  const waiters = aggregateWaiters(orders);
  const totalCovers = waiters.reduce((s, w) => s + w.covers, 0);

  // 3. Discounts
  const discUsers = discountsByUser(orders);
  const discDays = discountsByDay(orders);
  const discTotal = discUsers.reduce((s, g) => s + g.total, 0);
  const discBills = discUsers.reduce((s, g) => s + g.bills, 0);

  const presets = [
    { key: "today", label: "Today" },
    { key: "yesterday", label: "Yesterday" },
    { key: "7d", label: "Last 7 days" },
    { key: "month", label: "This month" },
    { key: "lastmonth", label: "Last month" },
  ];

  return (
    <div className="mx-auto max-w-5xl">
      <div className="mb-1 flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-bold tracking-tight">More reports</h1>
        <Link href="/reports" className="text-xs font-semibold" style={{ color: "var(--color-brand-strong)" }}>
          ← Back to Reports
        </Link>
      </div>
      <p className="mt-1 mb-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
        {from === to ? longDate(from) : `${longDate(from)} – ${longDate(to)}`} · by business day · voided bills and cancelled items are left out
        {multi ? ` · Outlet: ${user.branch_name} only` : ""}
      </p>

      <div className="mb-5 flex flex-wrap items-center gap-2">
        {presets.map((p) => (
          <Link
            key={p.key}
            href={`/reports/more?range=${p.key}`}
            className="rounded-full border px-3 py-1.5 text-xs font-semibold"
            style={{
              borderColor: range === p.key ? "var(--color-brand)" : "var(--color-line)",
              background: range === p.key ? "var(--color-brand-soft)" : "var(--color-surface)",
              color: range === p.key ? "var(--color-brand-strong)" : "var(--color-ink-2)",
            }}
          >
            {p.label}
          </Link>
        ))}
        <form action="/reports/more" className="flex flex-wrap items-center gap-1.5">
          <input type="date" name="from" defaultValue={from} max={today} className="field h-9 w-36 text-xs" />
          <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>to</span>
          <input type="date" name="to" defaultValue={to} max={today} className="field h-9 w-36 text-xs" />
          <button className="rounded-lg border px-3 py-2 text-xs font-semibold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
            Show
          </button>
        </form>
      </div>

      {multi && (
        <div className="card mb-4 p-3 text-xs" style={{ color: "var(--color-warn)" }}>
          {allOutlets ? "The outlet picker is on All outlets, but" : "Note:"} these reports cover the current outlet only ({user.branch_name}), so figures can differ from the main Reports page, which
          adds up all outlets.
        </div>
      )}

      {lookupError && (
        <div className="card mb-4 p-3 text-xs" style={{ color: "var(--color-bad)" }}>
          Some staff names or bill numbers could not be loaded ({friendlyDbError(lookupError)}). They may show as Unknown or blank.
        </div>
      )}

      {(ordersR.truncated || itemsR.truncated) && (
        <div className="card mb-4 p-3 text-xs" style={{ color: "var(--color-warn)" }}>
          This range is very large, so only the first {MAX_ROWS.toLocaleString("en-IN")} rows were read. Choose a shorter range for exact figures.
        </div>
      )}

      <div className="grid gap-4 lg:grid-cols-2">
        <Card
          title="Popular items"
          action={
            popular.length > 0 ? (
              <CsvButton
                filename={`popular_items_${from}_${to}.csv`}
                header={["Item", "Quantity", "Amount before tax"]}
                rows={popular.map((i) => [i.name, i.qty, i.amount])}
              />
            ) : null
          }
        >
          {itemsR.error ? <Err e={itemsR.error} /> : popular.length === 0 ? <Empty text="No items were sold in this period." /> : (
            <Table
              head={["Item", "Units", "Amount"]}
              rows={popular.map((i) => [i.name, String(i.qty), money(i.amount, c)])}
            />
          )}
          {popular.length >= TOP && <Note>Top {TOP} items by units sold.</Note>}
        </Card>

        <Card
          title="Slow and unsold items"
          action={
            slow.length + dead.length > 0 ? (
              <CsvButton
                filename={`slow_items_${from}_${to}.csv`}
                header={["Item", "Status", "Quantity", "Amount before tax"]}
                rows={[
                  ...dead.map((d) => [d.name, "No sales", 0, 0] as (string | number)[]),
                  ...slow.map((s) => [s.name, "Slow", s.qty, s.amount] as (string | number)[]),
                ]}
              />
            ) : null
          }
        >
          {itemsR.error || productsR.error || offHereR.error ? <Err e={(itemsR.error ?? productsR.error ?? offHereR.error) as DbErrorLike} /> : active.length === 0 ? (
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
                  <Table head={["Item"]} rows={dead.slice(0, TOP).map((d) => [d.name])} />
                  {dead.length > TOP && <Note>Showing {TOP} of {dead.length}.</Note>}
                </div>
              )}
              <h3 className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                Sold least ({slow.length})
              </h3>
              {slow.length === 0 ? <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>Nothing to show.</p> : (
                <Table head={["Item", "Units", "Amount"]} rows={slow.map((s) => [s.name, String(s.qty), money(s.amount, c)])} />
              )}
              <Note>Only items that are on the menu and available are counted.</Note>
            </>
          )}
        </Card>

        <Card
          title="Waiter-wise sales"
          action={
            waiters.length > 0 ? (
              <CsvButton
                filename={`waiters_${from}_${to}.csv`}
                header={["Staff", "Bills", "Covers", "Sales", "Average bill"]}
                rows={waiters.map((w) => [who(w.user_id), w.bills, w.covers, w.total, w.average])}
              />
            ) : null
          }
        >
          {ordersR.error ? <Err e={ordersR.error} /> : waiters.length === 0 ? <Empty text="No sales in this period." /> : (
            <>
              <Table
                head={["Staff", "Bills", "Covers", "Sales", "Average bill"]}
                rows={waiters.map((w) => [who(w.user_id), String(w.bills), w.covers > 0 ? String(w.covers) : "—", money(w.total, c), money(w.average, c)])}
              />
              <Note>
                The waiter is shown where one was recorded; otherwise the cashier who took the bill (counter and takeaway bills). Complimentary and staff-meal bills are not included.
                {totalCovers === 0 ? " Covers were not entered on these bills." : ""}
              </Note>
            </>
          )}
        </Card>

        {canFinancial && (
          <Card
            title="Discount summary"
            action={
              discUsers.length > 0 ? (
                <CsvButton
                  filename={`discounts_${from}_${to}.csv`}
                  header={["View", "Name / date", "Discounted bills", "Total discount", "Highest discount %"]}
                  rows={[
                    ...discUsers.map((g) => ["By cashier", who(g.key), g.bills, g.total, g.maxPercent] as (string | number)[]),
                    ...discDays.map((g) => ["By day", g.key, g.bills, g.total, g.maxPercent] as (string | number)[]),
                  ]}
                />
              ) : null
            }
          >
            {ordersR.error ? <Err e={ordersR.error} /> : discUsers.length === 0 ? <Empty text="No discounts were given in this period." /> : (
              <>
                <p className="mb-2 text-sm">
                  {discBills} discounted bill{discBills === 1 ? "" : "s"}, {money(discTotal, c)} given away.
                </p>
                <h3 className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>By cashier</h3>
                <Table
                  head={["Cashier", "Bills", "Discount", "Highest %"]}
                  rows={discUsers.map((g) => [who(g.key), String(g.bills), money(g.total, c), `${g.maxPercent}%`])}
                />
                <h3 className="mt-3 mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>By day</h3>
                <Table
                  head={["Day", "Bills", "Discount", "Highest %"]}
                  rows={discDays.map((g) => [longDate(g.key), String(g.bills), money(g.total, c), `${g.maxPercent}%`])}
                />
                <Note>The percentage is the discount as a share of the menu value of that bill, before tax.</Note>
              </>
            )}
          </Card>
        )}
      </div>

      {canFinancial && (
        <div className="mt-4">
          <Card
            title="Voids, cancels, refunds and discount approvals"
            action={
              auditRows.length > 0 ? (
                <CsvButton
                  filename={`audit_${from}_${to}.csv`}
                  header={["Time", "What happened", "Bill", "Details", "Amount", "Reason", "Done by"]}
                  rows={auditRows.map((r) => {
                    const d = auditDetail(r.action, r.new_value, r.old_value);
                    return [
                      dateTime(r.created_at, tz),
                      AUDIT_ACTION_LABEL[r.action] ?? r.action,
                      d.bill || (r.entity_id ? billOf.get(r.entity_id) ?? "" : ""),
                      d.detail,
                      d.amount ?? "",
                      d.reason,
                      who(r.user_id),
                    ];
                  })}
                />
              ) : null
            }
          >
            {auditError ? <Err e={auditError} /> : auditRows.length === 0 ? <Empty text="Nothing was voided, cancelled or refunded in this period." /> : (
              <>
                <Table
                  head={["Time", "What happened", "Bill", "Details", "Amount", "Reason", "Done by"]}
                  rows={auditRows.map((r) => {
                    const d = auditDetail(r.action, r.new_value, r.old_value);
                    return [
                      dateTime(r.created_at, tz),
                      AUDIT_ACTION_LABEL[r.action] ?? r.action,
                      d.bill || (r.entity_id ? billOf.get(r.entity_id) ?? "—" : "—"),
                      d.detail || "—",
                      d.amount == null ? "—" : money(d.amount, c),
                      d.reason || "—",
                      who(r.user_id),
                    ];
                  })}
                />
                {auditHitLimit && <Note>Showing the latest {AUDIT_EACH} of each kind. Choose a shorter range to see older entries.</Note>}
              </>
            )}
            <Note>
              From the activity log, by calendar date and for this outlet. Manager PIN approvals and bill adjustments with no discount are not listed. Reprints of bills are not recorded in the activity log, so they cannot be listed here.
            </Note>
          </Card>
        </div>
      )}
    </div>
  );
}

function Card({ title, action, children }: { title: string; action?: React.ReactNode; children: React.ReactNode }) {
  return (
    <section className="card p-4">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="text-sm font-bold">{title}</h2>
        {action}
      </div>
      {children}
    </section>
  );
}

function Table({ head, rows }: { head: string[]; rows: string[][] }) {
  return (
    <div className="max-h-80 overflow-auto">
      <table className="w-full text-sm">
        <thead>
          <tr style={{ color: "var(--color-ink-3)" }}>
            {head.map((h, i) => (
              <th key={h} className={`pb-2 pr-2 text-xs font-semibold ${i === 0 ? "text-left" : "text-right"}`}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} style={{ borderTop: "1px solid var(--color-line)" }}>
              {r.map((cell, j) => (
                <td key={j} className={`py-1.5 pr-2 ${j === 0 ? "text-left" : "text-right tabular-nums"}`}>
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function Empty({ text }: { text: string }) {
  return (
    <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
      {text}
    </p>
  );
}

function Note({ children }: { children: React.ReactNode }) {
  return (
    <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
      {children}
    </p>
  );
}

function Err({ e }: { e: DbErrorLike }) {
  return (
    <p className="text-sm" style={{ color: "var(--color-bad)" }}>
      {friendlyDbError(e)}
    </p>
  );
}
