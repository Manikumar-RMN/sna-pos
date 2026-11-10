import Link from "next/link";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { friendlyDbError } from "@/lib/db-error";
import { addDays, dateTime, isYmd, longDate, money, orderTypeLabel, todayIn } from "@/lib/format";
import { outletScope, rangeQuery } from "@/lib/reports-pack";
import { CsvButton } from "./csv-button";
import { OutletBanner } from "./_components/outlet-banner";
import { FilterForm } from "./_components/filter-form";
import { ReportList } from "./_components/report-list";
import type { OutletInfo } from "../outlet/outlet-switcher";

type Settlement = {
  methods: { method: string; kind: string; mode: string; payments: number; collected: number; refunded: number; voided: number; net: number }[];
  payments: { at: string; bill: string; method: string; amount: number; reference: string | null; status: string; by: string | null }[];
};

type JournalRow = { date: string; account: string; debit: number; credit: number; narration: string };

type RegisterRow = {
  type: string;
  date: string;
  number: string;
  against?: string;
  status: string;
  buyer_gstin: string | null;
  buyer_name: string | null;
  rate: number | null;
  taxable: number;
  cgst: number;
  sgst: number;
  igst: number;
  total: number;
};

type Report = {
  financial: boolean;
  summary: {
    bills: number;
    gross_sales: number;
    discounts: number;
    tax: number;
    rounding: number;
    /** Rounding on cash payments (the amount the till differs from the bill totals). */
    cash_rounding?: number;
    total_billed: number;
    average_bill: number;
    voided_bills: number;
    voided_value: number;
    /** Complimentary bills and staff meals, at menu value (closed at 0.00). Older databases do not send these. */
    complimentary_bills?: number;
    complimentary_value?: number;
    staff_meal_bills?: number;
    staff_meal_value?: number;
    refunds: number;
    refund_count: number;
    /** Money actually received: billed, less what is not yet paid, less refunds. */
    net_collected: number;
    /** Bills that still have something to pay, and how much. Older databases do not send these. */
    unpaid_bills?: number;
    unpaid_amount?: number;
    net_sales: number;
    service_charge: number;
    tax_included: number;
    exempt_sales: number;
  };
  by_day: { day: string; bills: number; total: number }[];
  by_hour: { hour: number; bills: number; total: number }[];
  by_item: { item: string; qty: number; amount: number }[];
  by_method: { method: string; bills: number; amount: number }[];
  by_type: { type: string; bills: number; total: number }[];
  tax: { component: string; rate: number; taxable: number; tax: number }[];
};

export default async function ReportsPage({
  searchParams,
}: {
  searchParams: Promise<{ range?: string; from?: string; to?: string }>;
}) {
  const user = await requireUser();
  if (!can(user, "report.view_sales")) {
    return (
      <div className="mx-auto max-w-md">
        <h1 className="text-xl font-bold tracking-tight">Reports</h1>
        <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Your role does not include viewing sales reports.
        </div>
      </div>
    );
  }

  const sp = await searchParams;
  const supabase = await createClient();
  // "Today" is the business day the bills are being counted to: the open day, or the last day worked.
  // (After a late close, or past midnight, this is not always the calendar date.)
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
  let from = today;
  let to = today;
  let range = sp.range ?? "today";
  if (isYmd(sp.from) && isYmd(sp.to)) {
    from = sp.from <= sp.to ? sp.from : sp.to;
    to = sp.from <= sp.to ? sp.to : sp.from;
    range = "custom";
  } else if (range === "yesterday") {
    from = to = addDays(today, -1);
  } else if (range === "7d") {
    from = addDays(today, -6);
  } else if (range === "month") {
    from = today.slice(0, 8) + "01";
  } else if (range === "lastmonth") {
    // The day before the 1st of this month is the last day of last month.
    to = addDays(today.slice(0, 8) + "01", -1);
    from = to.slice(0, 8) + "01";
  } else {
    range = "today";
  }

  const showRegister = user.country_code === "IN" && can(user, "report.view_financial");
  const showJournal = can(user, "report.view_financial") && has(user, "accounting");
  const multi = has(user, "multi_outlet") && user.outlet_count > 1;
  const [{ data, error }, { data: settleData }, { data: registerData }, { data: journalData }, { data: compareData }, { data: outletData }, { data: sessionData }] = await Promise.all([
    supabase.rpc("sales_report", { p_from: from, p_to: to }),
    supabase.rpc("settlement_report", { p_from: from, p_to: to }),
    showRegister ? supabase.rpc("gst_register", { p_from: from, p_to: to }) : Promise.resolve({ data: null }),
    showJournal ? supabase.rpc("accounting_journal", { p_from: from, p_to: to }) : Promise.resolve({ data: null }),
    multi ? supabase.rpc("outlet_comparison", { p_from: from, p_to: to }) : Promise.resolve({ data: null }),
    supabase.rpc("my_outlets"),
    supabase.rpc("session_report", { p_from: from, p_to: to }),
  ]);
  const sessions = (sessionData ?? []) as unknown as { session: string; bills: number; total: number; average: number; top_items: { item: string; qty: number }[] }[];
  const compare = (compareData ?? []) as unknown as { outlet: string; code: string; bills: number; total: number; average: number; discounts: number; voids: number; void_value: number }[];
  const outletInfo = (outletData as unknown as OutletInfo | null) ?? null;
  const scope = outletScope(outletInfo, { id: user.branch_id, name: user.branch_name });
  const showPicker = multi && (outletInfo?.outlets.length ?? 0) > 1;
  const canFinancial = can(user, "report.view_financial");
  // Inventory reports need the stock module (Professional) and stock.view; customer reports need customer.view.
  const reportAccess = {
    financial: canFinancial,
    stock: has(user, "stock") && (can(user, "stock.view") || can(user, "stock.manage")),
    customers: can(user, "customer.view"),
    loyalty: has(user, "loyalty") && can(user, "customer.view"),
    users: can(user, "user.manage"),
  };
  const keep = rangeQuery(sp);
  const rep = data as unknown as Report | null;
  const settle = settleData as unknown as Settlement | null;
  const c = user.currency_code;
  const unpaidAmount = Number(rep?.summary.unpaid_amount ?? 0);
  const unpaidBills = Number(rep?.summary.unpaid_bills ?? 0);
  const unpaidCount = `${unpaidBills} bill${unpaidBills === 1 ? "" : "s"}`;

  return (
    <div className="mx-auto max-w-6xl">
      <h1 className="text-xl font-bold tracking-tight">POS reports</h1>
      <p className="mt-1 mb-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Sales, operations, items and staff reports. Each opens with From and To dates, Display, Print and Excel.
      </p>
      <div className="mb-6"><ReportList access={reportAccess} section="pos" keep={keep} /></div>

      <div id="sales-summary" className="scroll-mt-4" />
      <h2 className="text-lg font-bold tracking-tight">Sales summary</h2>
      <p className="mt-1 mb-3 text-sm" style={{ color: "var(--color-ink-3)" }}>
        {from === to ? longDate(from) : `${longDate(from)} – ${longDate(to)}`} · voided bills are left out of every total
      </p>
      <OutletBanner scope={scope} info={outletInfo} showPicker={showPicker} />

      {multi && compare.length > 0 && (
        <div className="card mb-5 overflow-x-auto p-4">
          <h2 className="mb-2 font-display text-base font-bold">Outlets compared</h2>
          <table className="w-full text-sm">
            <thead>
              <tr className="text-left" style={{ color: "var(--color-ink-3)" }}>
                <th className="py-1.5 pr-3">Outlet</th>
                <th className="py-1.5 pr-3 text-right">Bills</th>
                <th className="py-1.5 pr-3 text-right">Sales</th>
                <th className="py-1.5 pr-3 text-right">Average bill</th>
                <th className="py-1.5 pr-3 text-right">Discounts</th>
                <th className="py-1.5 pr-3 text-right">Voids</th>
              </tr>
            </thead>
            <tbody>
              {compare.map((r) => (
                <tr key={r.code} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                  <td className="py-1.5 pr-3 font-semibold">{r.outlet}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{r.bills}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.total, c)}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.average, c)}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{money(r.discounts, c)}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">
                    {r.voids} ({money(r.void_value, c)})
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <FilterForm basePath="/reports" from={from} to={to} range={range} max={today} />
      <div className="mb-5" />

      {error || !rep ? (
        <div className="card p-5 text-sm" style={{ color: "var(--color-bad)" }}>
          {error ? friendlyDbError(error) : "The report could not be loaded."}
        </div>
      ) : (
        <>
          <div className="mb-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Kpi
              label="Total billed"
              value={money(rep.summary.total_billed, c)}
              strong
              note={unpaidAmount > 0 ? `Not yet paid: ${money(unpaidAmount, c)} · ${unpaidCount}` : undefined}
              warn
            />
            <Kpi label="Bills" value={String(rep.summary.bills)} />
            <Kpi label="Average bill" value={money(rep.summary.average_bill, c)} />
            <Kpi
              label="Money received"
              value={money(rep.summary.net_collected, c)}
              note={unpaidAmount > 0 ? "After unpaid bills and refunds" : "After refunds"}
            />
          </div>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card title="Summary">
              <Lines
                rows={
                  [
                    [rep.summary.tax_included > 0 ? "Menu sales (menu prices, before discount)" : "Food & drink sales (before discount and tax)", money(rep.summary.gross_sales, c)],
                    ["Discounts given", `−${money(rep.summary.discounts, c)}`],
                    rep.summary.service_charge > 0 ? ["Service charge", money(rep.summary.service_charge, c)] : null,
                    [
                      rep.summary.tax_included > 0 ? `Tax collected (${money(rep.summary.tax_included, c)} already inside menu prices)` : "Tax collected",
                      money(rep.summary.tax, c),
                    ],
                    ["Rounding", money(rep.summary.rounding, c)],
                    Math.abs(rep.summary.cash_rounding ?? 0) >= 0.005 ? ["Cash rounding (on cash payments)", money(rep.summary.cash_rounding ?? 0, c)] : null,
                    ["Total billed", money(rep.summary.total_billed, c)],
                    unpaidAmount > 0 ? [`Not yet paid (${unpaidCount})`, `−${money(unpaidAmount, c)}`] : null,
                    ["Net sales (excluding tax)", money(rep.summary.net_sales, c)],
                    rep.summary.exempt_sales > 0 ? ["Tax-exempt sales", money(rep.summary.exempt_sales, c)] : null,
                    [`Refunds (${rep.summary.refund_count})`, `−${money(rep.summary.refunds, c)}`],
                    [unpaidAmount > 0 ? "Money received (after unpaid bills and refunds)" : "Money received (after refunds)", money(rep.summary.net_collected, c)],
                    [`Voided bills (${rep.summary.voided_bills})`, money(rep.summary.voided_value, c)],
                    (rep.summary.complimentary_bills ?? 0) > 0
                      ? [`Complimentary bills (${rep.summary.complimentary_bills}), menu value`, money(rep.summary.complimentary_value ?? 0, c)]
                      : null,
                    (rep.summary.staff_meal_bills ?? 0) > 0 ? [`Staff meals (${rep.summary.staff_meal_bills}), menu value`, money(rep.summary.staff_meal_value ?? 0, c)] : null,
                  ].filter((r): r is [string, string] => r !== null)
                }
              />
            </Card>

            <Card
              title="Settlement by payment mode"
              action={
                settle && settle.payments.length > 0 ? (
                  <CsvButton
                    filename={`settlement_${from}_${to}.csv`}
                    header={["Time", "Bill", "Payment mode", "Amount", "Reference", "Status", "Taken by"]}
                    rows={settle.payments.map((p) => [dateTime(p.at, user.timezone), p.bill, p.method, p.amount, p.reference ?? "", p.status === "refunded" ? "Voided" : "Paid", p.by ?? ""])}
                  />
                ) : null
              }
            >
              {!settle || settle.methods.length === 0 ? (
                <Empty />
              ) : (
                <>
                  <Table
                    head={["Mode", "Payments", "Collected", "Refunds / voids", "To settle"]}
                    rows={settle.methods.map((m) => [
                      m.mode === "gateway" ? m.method : `${m.method}`,
                      String(m.payments),
                      money(m.collected, c),
                      m.refunded + m.voided > 0 ? `−${money(m.refunded + m.voided, c)}` : "—",
                      money(m.net, c),
                    ])}
                  />
                  <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    Match each line with your cash drawer, card machine settlement and UPI / wallet statements. The CSV lists every
                    payment with its reference.
                  </p>
                </>
              )}
            </Card>

            {rep.financial && (
              <Card
                title="GST / tax collected"
                action={
                  rep.tax.length > 0 ? (
                    <CsvButton
                      filename={`tax_${from}_${to}.csv`}
                      header={["Component", "Rate %", "Taxable value", "Tax"]}
                      rows={rep.tax.map((t) => [t.component, t.rate, t.taxable, t.tax])}
                    />
                  ) : null
                }
              >
                {rep.tax.length === 0 ? <Empty /> : (
                  <Table
                    head={["Component", "Taxable value", "Tax"]}
                    rows={rep.tax.map((t) => [`${t.component} ${Number(t.rate)}%`, money(t.taxable, c), money(t.tax, c)])}
                  />
                )}
                <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                  For your GST filing. Confirm with your accountant.
                </p>
              </Card>
            )}

            {showJournal && (
              <Card
                title="Accounting export"
                action={
                  ((journalData ?? []) as unknown as JournalRow[]).length > 0 ? (
                    <CsvButton
                      filename={`journal_${from}_${to}.csv`}
                      header={["Date", "Account", "Debit", "Credit", "Narration"]}
                      rows={((journalData ?? []) as unknown as JournalRow[]).map((r) => [r.date, r.account, r.debit, r.credit, r.narration])}
                    />
                  ) : null
                }
              >
                {((journalData ?? []) as unknown as JournalRow[]).length === 0 ? (
                  <Empty />
                ) : (
                  <Table
                    head={["Account", "Debit", "Credit"]}
                    rows={Object.values(
                      ((journalData ?? []) as unknown as JournalRow[]).reduce<Record<string, { a: string; d: number; c: number }>>((acc, r) => {
                        const k = r.account;
                        acc[k] = acc[k] ?? { a: k, d: 0, c: 0 };
                        acc[k].d += Number(r.debit);
                        acc[k].c += Number(r.credit);
                        return acc;
                      }, {}),
                    ).map((x) => [x.a, x.d ? money(x.d, c) : "", x.c ? money(x.c, c) : ""])}
                  />
                )}
                <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                  One balanced sales journal per day (money received, sales, each tax, service charge, round-off, credit notes). Import the
                  CSV into Tally, Zoho Books, Xero or QuickBooks; your accountant maps the account names once.
                </p>
              </Card>
            )}

            {showRegister && (
              <Card
                title="GST bill register"
                action={
                  ((registerData ?? []) as unknown as RegisterRow[]).length > 0 ? (
                    <CsvButton
                      filename={`gst_register_${from}_${to}.csv`}
                      header={["Type", "Date", "Number", "Against bill", "Status", "Customer GSTIN", "Customer name", "GST rate %", "Taxable value", "CGST", "SGST/UTGST", "IGST", "Total"]}
                      rows={((registerData ?? []) as unknown as RegisterRow[]).map((r) => [
                        r.type,
                        r.date,
                        r.number,
                        r.against ?? "",
                        r.status,
                        r.buyer_gstin ?? "",
                        r.buyer_name ?? "",
                        r.rate ?? "",
                        r.taxable,
                        r.cgst,
                        r.sgst,
                        r.igst,
                        r.total,
                      ])}
                    />
                  ) : null
                }
              >
                {((registerData ?? []) as unknown as RegisterRow[]).length === 0 ? (
                  <Empty />
                ) : (
                  <>
                    <p className="text-sm">
                      {((registerData ?? []) as unknown as RegisterRow[]).filter((r) => r.type === "Bill").length} bills,{" "}
                      {((registerData ?? []) as unknown as RegisterRow[]).filter((r) => r.type !== "Bill").length} credit notes,{" "}
                      {((registerData ?? []) as unknown as RegisterRow[]).filter((r) => r.buyer_gstin).length} with a customer GSTIN (B2B).
                    </p>
                    <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                      Every bill and credit note with its GST split, for GSTR-1. Download the CSV for your accountant.
                    </p>
                  </>
                )}
              </Card>
            )}

            <Card title="By meal session">
              {sessions.length === 0 ? <Empty /> : (
                <Table
                  head={["Session", "Bills", "Total", "Average bill", "Top items"]}
                  rows={sessions.map((x) => [
                    x.session,
                    String(x.bills),
                    money(x.total, c),
                    money(x.average, c),
                    x.top_items.slice(0, 3).map((t) => `${t.item} ×${Number(t.qty)}`).join(", "),
                  ])}
                />
              )}
            </Card>

            <Card title="Order type">
              {rep.by_type.length === 0 ? <Empty /> : (
                <Table
                  head={["Type", "Bills", "Total"]}
                  rows={rep.by_type.map((t) => [orderTypeLabel[t.type] ?? t.type, String(t.bills), money(t.total, c)])}
                />
              )}
            </Card>

            <Card
              title="Items sold"
              action={
                rep.by_item.length > 0 ? (
                  <CsvButton
                    filename={`items_${from}_${to}.csv`}
                    header={["Item", "Quantity", "Amount before tax"]}
                    rows={rep.by_item.map((i) => [i.item, i.qty, i.amount])}
                  />
                ) : null
              }
            >
              {rep.by_item.length === 0 ? <Empty /> : (
                <Table
                  head={["Item", "Qty", "Amount"]}
                  rows={rep.by_item.map((i) => [i.item, String(Number(i.qty)), money(i.amount, c)])}
                />
              )}
            </Card>

            <Card title={from === to ? "By hour" : "By day"}
              action={
                from !== to && rep.by_day.length > 0 ? (
                  <CsvButton
                    filename={`daily_${from}_${to}.csv`}
                    header={["Date", "Bills", "Total billed"]}
                    rows={rep.by_day.map((d) => [d.day, d.bills, d.total])}
                  />
                ) : null
              }
            >
              {from === to ? (
                rep.by_hour.length === 0 ? <Empty /> : (
                  <Table
                    head={["Hour", "Bills", "Total"]}
                    rows={rep.by_hour.map((h) => [`${String(h.hour).padStart(2, "0")}:00–${String(h.hour + 1).padStart(2, "0")}:00`, String(h.bills), money(h.total, c)])}
                  />
                )
              ) : rep.by_day.length === 0 ? <Empty /> : (
                <Table
                  head={["Date", "Bills", "Total"]}
                  rows={rep.by_day.map((d) => [longDate(d.day), String(d.bills), money(d.total, c)])}
                />
              )}
            </Card>
          </div>
        </>
      )}
    </div>
  );
}

function Kpi({ label, value, strong, note, warn }: { label: string; value: string; strong?: boolean; note?: string; warn?: boolean }) {
  return (
    <div className="card p-4">
      <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
        {label}
      </div>
      <div className="mt-1 text-2xl font-bold tabular-nums" style={strong ? { color: "var(--color-brand-strong)" } : undefined}>
        {value}
      </div>
      {note && (
        <div className="mt-1 text-xs font-semibold tabular-nums" style={{ color: warn ? "var(--color-warn)" : "var(--color-ink-3)" }}>
          {note}
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

function Lines({ rows }: { rows: [string, string][] }) {
  return (
    <dl className="space-y-1.5 text-sm">
      {rows.map(([k, v]) => (
        <div key={k} className="flex justify-between gap-3">
          <dt style={{ color: "var(--color-ink-2)" }}>{k}</dt>
          <dd className="tabular-nums">{v}</dd>
        </div>
      ))}
    </dl>
  );
}

function Table({ head, rows }: { head: string[]; rows: string[][] }) {
  return (
    <div className="max-h-80 overflow-y-auto">
      <table className="w-full text-sm">
        <thead>
          <tr style={{ color: "var(--color-ink-3)" }}>
            {head.map((h, i) => (
              <th key={h} className={`pb-2 text-xs font-semibold ${i === 0 ? "text-left" : "text-right"}`}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} style={{ borderTop: "1px solid var(--color-line)" }}>
              {r.map((cell, j) => (
                <td key={j} className={`py-1.5 ${j === 0 ? "text-left" : "text-right tabular-nums"}`}>
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

function Empty() {
  return (
    <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
      No sales in this period.
    </p>
  );
}
