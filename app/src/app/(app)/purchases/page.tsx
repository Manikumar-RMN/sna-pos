import Link from "next/link";
import { can, has, requireUser, type CurrentUser } from "@/lib/auth";
import { UpgradeNote } from "../upgrade-note";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import { addDays, money, todayIn } from "@/lib/format";
import {
  EMPTY_REPORT,
  dayLabel,
  isUuid,
  onOrderQty,
  qtyText,
  ymdIn,
  type Ingredient,
  type IngredientNames,
  type OrderLine,
  type OrderRow,
  type PaymentRow,
  type PurchaseReport,
  type ReceiptRow,
  type StockedIngredient,
  type SupplierRow,
} from "./helpers";
import { OrdersTab } from "./orders-tab";
import { ReceiveTab } from "./receive-tab";
import { SuppliersTab } from "./suppliers-tab";
import { OwedList } from "./to-pay-tab";
import { AddSupplierFirst } from "./ui";

const TABS = [
  { key: "receive", label: "Receive goods" },
  { key: "orders", label: "Orders" },
  { key: "suppliers", label: "Suppliers" },
  { key: "pay", label: "To pay" },
] as const;
type TabKey = (typeof TABS)[number]["key"];

type Db = Awaited<ReturnType<typeof createClient>>;
type Params = Record<string, string | string[] | undefined>;
const one = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);

const ORDER_COLS = "id, number, supplier_id, status, expected_on, notes, total, created_at";
type OrderDb = { id: string; number: string; supplier_id: string; status: string; expected_on: string | null; notes: string | null; total: number | string; created_at: string };

const pill = "inline-flex min-h-10 items-center rounded-full border px-4 text-sm font-semibold";
const pillStyle = (on: boolean): React.CSSProperties => ({
  borderColor: on ? "var(--color-brand)" : "var(--color-line)",
  background: on ? "var(--color-brand)" : "transparent",
  color: on ? "#fff" : "var(--color-ink-2)",
});

export default async function PurchasesPage({ searchParams }: { searchParams: Promise<Params> }) {
  const user = await requireUser();
  if (!can(user, "stock.manage")) {
    return (
      <div className="card mx-auto max-w-md p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        Your role does not include stock. An owner can give the &ldquo;Manage stock&rdquo; right in Settings → Security profiles.
      </div>
    );
  }
  if (!has(user, "stock")) {
    return (
      <div className="mx-auto max-w-md">
        <UpgradeNote feature="Stock and recipes" />
      </div>
    );
  }

  const sp = await searchParams;
  const tabParam = one(sp.tab);
  const tab: TabKey = TABS.find((t) => t.key === tabParam)?.key ?? "receive";

  const supabase = await createClient();
  // Every tab needs the suppliers, if only to say "add one first".
  const { data: supplierRows, error: supplierError } = await supabase
    .from("suppliers")
    .select("id, name, contact_person, phone, email, tax_no, address, payment_days, notes, is_active")
    .order("name");
  const suppliers: SupplierRow[] = (supplierRows ?? []).map((s) => ({ ...s, payment_days: Number(s.payment_days) }));

  return (
    <div className="mx-auto max-w-4xl">
      <h1 className="text-xl font-bold tracking-tight">Purchases</h1>
      <p className="mt-1 mb-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Order from suppliers, record what arrives and keep track of what you owe{user.outlet_count > 1 ? ` — for ${user.branch_name}` : ""}.
      </p>
      <nav aria-label="Purchases" className="mb-4 flex flex-wrap gap-1.5">
        {TABS.map((t) => (
          <Link key={t.key} href={t.key === "receive" ? "/purchases" : `/purchases?tab=${t.key}`} aria-current={tab === t.key ? "page" : undefined} className={pill} style={pillStyle(tab === t.key)}>
            {t.label}
          </Link>
        ))}
      </nav>

      {supplierError ? (
        <LoadError what="the suppliers" message={friendlyDbError(supplierError)} />
      ) : tab === "receive" ? (
        <ReceiveSection supabase={supabase} user={user} suppliers={suppliers} po={one(sp.po) ?? null} />
      ) : tab === "orders" ? (
        <OrdersSection supabase={supabase} user={user} suppliers={suppliers} low={one(sp.low) === "1"} />
      ) : tab === "suppliers" ? (
        <SuppliersSection supabase={supabase} user={user} suppliers={suppliers} />
      ) : suppliers.length === 0 ? (
        <AddSupplierFirst />
      ) : (
        <PaySection supabase={supabase} user={user} period={one(sp.period) === "last" ? "last" : "this"} />
      )}
    </div>
  );
}

function LoadError({ what, message }: { what: string; message: string }) {
  return (
    <div className="card p-5 text-sm" role="alert" style={{ color: "var(--color-ink-2)" }}>
      <b style={{ color: "var(--color-bad)" }}>Could not load {what}.</b> {message} Refresh the page to try again.
    </div>
  );
}

/**
 * The lines of the given orders. Read in pages, because one request returns a
 * limited number of rows and a long list of orders can hold more than that.
 */
async function orderLines(supabase: Db, ids: string[], names: IngredientNames): Promise<Map<string, OrderLine[]>> {
  const map = new Map<string, OrderLine[]>();
  if (ids.length === 0) return map;
  const PAGE = 500;
  for (let page = 0; page < 40; page++) {
    const { data } = await supabase
      .from("purchase_order_lines")
      .select("id, purchase_order_id, ingredient_id, qty, unit_cost, received_qty")
      .in("purchase_order_id", ids)
      .order("id")
      .range(page * PAGE, page * PAGE + PAGE - 1);
    for (const l of data ?? []) {
      const list = map.get(l.purchase_order_id) ?? [];
      list.push({ ingredient_id: l.ingredient_id, qty: Number(l.qty), unit_cost: Number(l.unit_cost), received_qty: Number(l.received_qty) });
      map.set(l.purchase_order_id, list);
    }
    if (!data || data.length < PAGE) break;
  }
  // Lines have no order of their own: show them by ingredient name.
  const nameOf = (id: string) => names[id]?.name ?? "";
  for (const list of map.values()) list.sort((a, b) => nameOf(a.ingredient_id).localeCompare(nameOf(b.ingredient_id)));
  return map;
}

/**
 * The payments made on the given receipts, by receipt id, oldest first. An undo
 * is stored as its own negative entry: here it only marks the payment it undoes
 * as undone (with the reason), it is not listed as a payment itself.
 */
async function receiptPayments(supabase: Db, receiptIds: string[]): Promise<Record<string, PaymentRow[]>> {
  const out: Record<string, PaymentRow[]> = {};
  // A long list of ids does not fit in one request, so ask for them a hundred at a time (normally that is one request).
  for (let at = 0; at < receiptIds.length; at += 100) {
    const { data } = await supabase
      .from("supplier_payments")
      .select("id, goods_receipt_id, amount, method, reference, paid_on, from_till, reverses_id, reason, created_at")
      .in("goods_receipt_id", receiptIds.slice(at, at + 100))
      .order("created_at")
      .order("id");
    const rows = data ?? [];
    const undoOf = new Map<string, string | null>();
    for (const p of rows) if (p.reverses_id) undoOf.set(p.reverses_id, p.reason);
    for (const p of rows) {
      if (p.reverses_id) continue;
      (out[p.goods_receipt_id] ??= []).push({
        id: p.id,
        receipt_id: p.goods_receipt_id,
        paid_on: p.paid_on,
        method: p.method,
        amount: Number(p.amount),
        reference: p.reference,
        from_till: p.from_till,
        undone: undoOf.has(p.id),
        undo_reason: undoOf.get(p.id) ?? null,
      });
    }
  }
  return out;
}

function toOrder(p: OrderDb, lines: Map<string, OrderLine[]>, tz: string): OrderRow {
  return {
    id: p.id,
    number: p.number,
    supplier_id: p.supplier_id,
    status: p.status,
    expected_on: p.expected_on,
    notes: p.notes,
    total: Number(p.total),
    date: ymdIn(p.created_at, tz),
    lines: lines.get(p.id) ?? [],
  };
}

type SectionProps = { supabase: Db; user: CurrentUser; suppliers: SupplierRow[] };

async function ReceiveSection({ supabase, user, suppliers, po }: SectionProps & { po: string | null }) {
  const today = todayIn(user.timezone);
  const open = ["ordered", "part_received"];
  const [{ data: ings, error: ingError }, { data: pos }, { data: grs, error: grError }] = await Promise.all([
    supabase.from("ingredients").select("id, name, unit, cost_per_unit, is_active, purchase_unit, purchase_factor").order("name"),
    supabase.from("purchase_orders").select(ORDER_COLS).in("status", open).order("created_at", { ascending: false }).limit(100),
    supabase
      .from("goods_receipts")
      .select("id, number, supplier_id, supplier_bill_no, received_on, total, paid_total, status, cancel_reason")
      .order("created_at", { ascending: false })
      .limit(20),
  ]);
  if (ingError) return <LoadError what="the ingredients" message={friendlyDbError(ingError)} />;
  if (grError) return <LoadError what="the goods received" message={friendlyDbError(grError)} />;

  const orderRows: OrderDb[] = [...(pos ?? [])];
  // Opened from an order that is not among the newest open ones: fetch that one too.
  if (po && isUuid(po) && !orderRows.some((o) => o.id === po)) {
    const { data: extra } = await supabase.from("purchase_orders").select(ORDER_COLS).eq("id", po).in("status", open).maybeSingle();
    if (extra) orderRows.push(extra);
  }

  const names: IngredientNames = {};
  for (const i of ings ?? []) names[i.id] = { name: i.name, unit: i.unit };
  const ingredients: Ingredient[] = (ings ?? []).filter((i) => i.is_active).map((i) => ({ id: i.id, name: i.name, unit: i.unit, cost: Number(i.cost_per_unit), ...(i.purchase_unit ? { buyUnit: i.purchase_unit, buyFactor: Number(i.purchase_factor) } : {}) }));
  const [lines, payments] = await Promise.all([
    orderLines(
      supabase,
      orderRows.map((o) => o.id),
      names,
    ),
    receiptPayments(
      supabase,
      (grs ?? []).map((g) => g.id),
    ),
  ]);
  const receipts: ReceiptRow[] = (grs ?? []).map((g) => {
    const total = Number(g.total);
    const paid = Number(g.paid_total);
    return {
      id: g.id,
      number: g.number,
      supplier_id: g.supplier_id,
      bill_no: g.supplier_bill_no,
      received_on: g.received_on,
      total,
      paid,
      owed: Math.max(0, Math.round((total - paid) * 100) / 100),
      cancelled: g.status === "cancelled",
      cancel_reason: g.cancel_reason,
    };
  });

  return (
    <ReceiveTab
      suppliers={suppliers.filter((s) => s.is_active).map((s) => ({ id: s.id, name: s.name }))}
      supplierNames={Object.fromEntries(suppliers.map((s) => [s.id, s.name]))}
      ingredients={ingredients}
      names={names}
      openOrders={orderRows.map((o) => toOrder(o, lines, user.timezone))}
      receipts={receipts}
      payments={payments}
      currency={user.currency_code}
      country={user.country_code}
      today={today}
      initialPo={po}
      canTill={can(user, "cash.movement")}
    />
  );
}

async function OrdersSection({ supabase, user, suppliers, low }: SectionProps & { low: boolean }) {
  const today = todayIn(user.timezone);
  const LIMIT = 50;
  const [{ data: report, error: stockError }, { data: ings }, { data: pos, error: poError }, { data: openPos, error: openError }] = await Promise.all([
    // Only the stock levels are used here, so one day is enough.
    supabase.rpc("stock_report", { p_from: today, p_to: today }),
    supabase.from("ingredients").select("id, name, unit"),
    supabase.from("purchase_orders").select(ORDER_COLS).order("created_at", { ascending: false }).limit(LIMIT),
    // Every order still on its way (not only the newest ones listed), so "Fill from low stock" does not suggest it again.
    supabase.from("purchase_orders").select("id, status").in("status", ["ordered", "part_received"]).order("created_at", { ascending: false }).limit(300),
  ]);
  if (stockError) return <LoadError what="the stock levels" message={friendlyDbError(stockError)} />;
  if (poError) return <LoadError what="the purchase orders" message={friendlyDbError(poError)} />;
  if (openError) return <LoadError what="the purchase orders" message={friendlyDbError(openError)} />;

  const levels = ((report ?? { levels: [] }) as unknown as { levels: { id: string; name: string; unit: string; cost: number | string; reorder: number | string; stock: number | string }[] }).levels ?? [];
  const ingredients: StockedIngredient[] = levels.map((l) => ({ id: l.id, name: l.name, unit: l.unit, cost: Number(l.cost), stock: Number(l.stock), reorder: Number(l.reorder) }));
  const names: IngredientNames = {};
  for (const i of ings ?? []) names[i.id] = { name: i.name, unit: i.unit };
  for (const i of ingredients) names[i.id] = { name: i.name, unit: i.unit };
  const lines = await orderLines(
    supabase,
    (pos ?? []).map((o) => o.id),
    names,
  );
  // Open orders that are older than the ones listed: their lines are needed for the sums only.
  const listed = new Set((pos ?? []).map((o) => o.id));
  const olderOpen = (openPos ?? []).filter((o) => !listed.has(o.id)).map((o) => o.id);
  const olderLines = new Map<string, OrderLine[]>();
  for (let at = 0; at < olderOpen.length; at += 100) {
    for (const [id, list] of await orderLines(supabase, olderOpen.slice(at, at + 100), names)) olderLines.set(id, list);
  }
  const onOrder = onOrderQty((openPos ?? []).map((o) => ({ status: o.status, lines: lines.get(o.id) ?? olderLines.get(o.id) ?? [] })));

  return (
    <OrdersTab
      orders={(pos ?? []).map((o) => toOrder(o, lines, user.timezone))}
      suppliers={suppliers}
      ingredients={ingredients}
      onOrder={onOrder}
      names={names}
      currency={user.currency_code}
      restaurant={user.trading_name}
      outlet={user.branch_name}
      autoLow={low}
      capped={(pos ?? []).length >= LIMIT}
    />
  );
}

/** purchase_report() with every figure as a real number. */
function cleanReport(json: unknown): PurchaseReport {
  const r = (json ?? {}) as Partial<PurchaseReport>;
  const t = r.totals ?? EMPTY_REPORT.totals;
  return {
    totals: { receipts: Number(t.receipts ?? 0), bought: Number(t.bought ?? 0), owed: Number(t.owed ?? 0), overdue: Number(t.overdue ?? 0) },
    by_supplier: (r.by_supplier ?? []).map((s) => ({ ...s, receipts: Number(s.receipts), total: Number(s.total), paid: Number(s.paid), owed: Number(s.owed) })),
    owed: (r.owed ?? []).map((o) => ({ ...o, total: Number(o.total), paid: Number(o.paid), owed: Number(o.owed), overdue: o.overdue === true })),
    by_ingredient: (r.by_ingredient ?? []).map((i) => ({ ...i, qty: Number(i.qty), amount: Number(i.amount), avg_cost: i.avg_cost == null ? null : Number(i.avg_cost) })),
  };
}

async function SuppliersSection({ supabase, user, suppliers }: SectionProps) {
  const today = todayIn(user.timezone);
  const [{ data: report, error }, { data: country }] = await Promise.all([
    // The list of what is still owed does not depend on the dates.
    supabase.rpc("purchase_report", { p_from: today, p_to: today }),
    supabase.from("countries").select("tax_id_label").eq("code", user.country_code).maybeSingle(),
  ]);
  if (error) return <LoadError what="what is owed to suppliers" message={friendlyDbError(error)} />;
  const owed: Record<string, number> = {};
  for (const o of cleanReport(report).owed) owed[o.supplier_id] = Math.round(((owed[o.supplier_id] ?? 0) + o.owed) * 100) / 100;
  return <SuppliersTab suppliers={suppliers} owed={owed} currency={user.currency_code} taxLabel={country?.tax_id_label ?? "Tax number"} />;
}

async function PaySection({ supabase, user, period }: Omit<SectionProps, "suppliers"> & { period: "this" | "last" }) {
  const today = todayIn(user.timezone);
  const monthStart = today.slice(0, 8) + "01";
  const lastEnd = addDays(monthStart, -1);
  const lastStart = lastEnd.slice(0, 8) + "01";
  const [now, last] = await Promise.all([
    supabase.rpc("purchase_report", { p_from: monthStart, p_to: today }),
    period === "last" ? supabase.rpc("purchase_report", { p_from: lastStart, p_to: lastEnd }) : Promise.resolve(null),
  ]);
  const error = now.error ?? last?.error;
  if (error) return <LoadError what="the purchase figures" message={friendlyDbError(error)} />;

  const thisMonth = cleanReport(now.data);
  const shown = last ? cleanReport(last.data) : thisMonth;
  const m = (n: number) => money(n, user.currency_code);
  const owed = [...thisMonth.owed].sort((a, b) => (a.due_on ?? "9999").localeCompare(b.due_on ?? "9999") || a.received_on.localeCompare(b.received_on));
  const payments = await receiptPayments(
    supabase,
    owed.map((o) => o.id),
  );
  const figures = [
    { label: "Bought this month", value: thisMonth.totals.bought, bad: false },
    { label: "Owed in total", value: thisMonth.totals.owed, bad: false },
    { label: "Overdue", value: thisMonth.totals.overdue, bad: thisMonth.totals.overdue > 0 },
  ];
  const range = period === "last" ? `${dayLabel(lastStart)} – ${dayLabel(lastEnd)}` : `${dayLabel(monthStart)} – ${dayLabel(today)}`;

  return (
    <div className="space-y-5">
      <div className="grid gap-3 sm:grid-cols-3">
        {figures.map((f) => (
          <div key={f.label} className="card p-4">
            <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              {f.label}
            </div>
            <div className="font-display mt-1 text-2xl font-bold tabular-nums" style={{ color: f.bad ? "var(--color-bad)" : undefined }}>
              {m(f.value)}
            </div>
          </div>
        ))}
      </div>

      <OwedList owed={owed} payments={payments} currency={user.currency_code} country={user.country_code} today={today} canTill={can(user, "cash.movement")} />

      <section>
        <h2 className="mb-2 text-sm font-bold">What you bought</h2>
        <div className="flex flex-wrap items-center gap-1.5">
          <Link href="/purchases?tab=pay" scroll={false} aria-current={period === "this" ? "true" : undefined} className={pill} style={pillStyle(period === "this")}>
            This month
          </Link>
          <Link href="/purchases?tab=pay&period=last" scroll={false} aria-current={period === "last" ? "true" : undefined} className={pill} style={pillStyle(period === "last")}>
            Last month
          </Link>
          <span className="ml-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            {range}
          </span>
        </div>

        <div className="card mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <caption className="px-3 pt-3 text-left text-xs font-bold">By supplier</caption>
            <thead>
              <tr style={{ color: "var(--color-ink-3)" }}>
                <th className="px-3 py-2 text-left text-xs font-semibold">Supplier</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Deliveries</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Bought</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Paid</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Still owed</th>
              </tr>
            </thead>
            <tbody>
              {shown.by_supplier.length === 0 && (
                <tr>
                  <td colSpan={5} className="px-3 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                    Nothing was received in this period.
                  </td>
                </tr>
              )}
              {shown.by_supplier.map((s) => (
                <tr key={s.supplier_id} style={{ borderTop: "1px solid var(--color-line)" }}>
                  <td className="px-3 py-2">{s.supplier}</td>
                  <td className="px-3 py-2 text-right tabular-nums">{s.receipts}</td>
                  <td className="px-3 py-2 text-right tabular-nums">{m(s.total)}</td>
                  <td className="px-3 py-2 text-right tabular-nums">{m(s.paid)}</td>
                  <td className="px-3 py-2 text-right tabular-nums" style={{ color: s.owed > 0 ? "var(--color-bad)" : undefined, fontWeight: s.owed > 0 ? 700 : 400 }}>
                    {m(s.owed)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="card mt-3 overflow-x-auto">
          <table className="w-full text-sm">
            <caption className="px-3 pt-3 text-left text-xs font-bold">By ingredient</caption>
            <thead>
              <tr style={{ color: "var(--color-ink-3)" }}>
                <th className="px-3 py-2 text-left text-xs font-semibold">Ingredient</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Quantity</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Amount</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Average cost</th>
              </tr>
            </thead>
            <tbody>
              {shown.by_ingredient.length === 0 && (
                <tr>
                  <td colSpan={4} className="px-3 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                    Nothing was received in this period.
                  </td>
                </tr>
              )}
              {shown.by_ingredient.map((i, n) => (
                <tr key={n} style={{ borderTop: "1px solid var(--color-line)" }}>
                  <td className="px-3 py-2">
                    {i.ingredient}
                    {i.category && (
                      <span className="ml-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {i.category}
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums">
                    {qtyText(i.qty)} {i.unit}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums">{m(i.amount)}</td>
                  <td className="px-3 py-2 text-right tabular-nums">{i.avg_cost == null ? "—" : `${m(i.avg_cost)} / ${i.unit}`}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Amounts by ingredient are for the goods only. Tax and other charges on a supplier&rsquo;s bill are counted in the supplier totals.
        </p>
      </section>
    </div>
  );
}
