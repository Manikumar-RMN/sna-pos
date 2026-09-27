import Link from "next/link";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { addDays, dateTime, isYmd, longDate, money, orderTypeLabel, todayIn } from "@/lib/format";
import { CsvButton } from "./csv-button";

type Settlement = {
  methods: { method: string; kind: string; mode: string; payments: number; collected: number; refunded: number; voided: number; net: number }[];
  payments: { at: string; bill: string; method: string; amount: number; reference: string | null; status: string; by: string | null }[];
};

type Report = {
  financial: boolean;
  summary: {
    bills: number;
    gross_sales: number;
    discounts: number;
    tax: number;
    rounding: number;
    total_billed: number;
    average_bill: number;
    voided_bills: number;
    voided_value: number;
    refunds: number;
    refund_count: number;
    net_collected: number;
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
  const today = todayIn(user.timezone);
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
  } else {
    range = "today";
  }

  const supabase = await createClient();
  const [{ data, error }, { data: settleData }] = await Promise.all([
    supabase.rpc("sales_report", { p_from: from, p_to: to }),
    supabase.rpc("settlement_report", { p_from: from, p_to: to }),
  ]);
  const rep = data as unknown as Report | null;
  const settle = settleData as unknown as Settlement | null;
  const c = user.currency_code;

  const presets = [
    { key: "today", label: "Today" },
    { key: "yesterday", label: "Yesterday" },
    { key: "7d", label: "Last 7 days" },
    { key: "month", label: "This month" },
  ];

  return (
    <div className="mx-auto max-w-5xl">
      <h1 className="text-xl font-bold tracking-tight">Reports</h1>
      <p className="mt-1 mb-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
        {from === to ? longDate(from) : `${longDate(from)} – ${longDate(to)}`} · voided bills are left out of every total
      </p>

      <div className="mb-5 flex flex-wrap items-center gap-2">
        {presets.map((p) => (
          <Link
            key={p.key}
            href={`/reports?range=${p.key}`}
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
        <form action="/reports" className="flex flex-wrap items-center gap-1.5">
          <input type="date" name="from" defaultValue={from} max={today} className="field h-9 w-36 text-xs" />
          <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>to</span>
          <input type="date" name="to" defaultValue={to} max={today} className="field h-9 w-36 text-xs" />
          <button className="rounded-lg border px-3 py-2 text-xs font-semibold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
            Show
          </button>
        </form>
      </div>

      {error || !rep ? (
        <div className="card p-5 text-sm" style={{ color: "var(--color-bad)" }}>
          {error?.message ?? "The report could not be loaded."}
        </div>
      ) : (
        <>
          <div className="mb-5 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Kpi label="Total billed" value={money(rep.summary.total_billed, c)} strong />
            <Kpi label="Bills" value={String(rep.summary.bills)} />
            <Kpi label="Average bill" value={money(rep.summary.average_bill, c)} />
            <Kpi label="Billed minus refunds" value={money(rep.summary.net_collected, c)} />
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
                    ["Total billed", money(rep.summary.total_billed, c)],
                    ["Net sales (excluding tax)", money(rep.summary.net_sales, c)],
                    rep.summary.exempt_sales > 0 ? ["Tax-exempt sales", money(rep.summary.exempt_sales, c)] : null,
                    [`Refunds (${rep.summary.refund_count})`, `−${money(rep.summary.refunds, c)}`],
                    [`Voided bills (${rep.summary.voided_bills})`, money(rep.summary.voided_value, c)],
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

function Kpi({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="card p-4">
      <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
        {label}
      </div>
      <div className="mt-1 text-2xl font-bold tabular-nums" style={strong ? { color: "var(--color-brand-strong)" } : undefined}>
        {value}
      </div>
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
