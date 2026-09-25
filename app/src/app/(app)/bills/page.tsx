import Link from "next/link";
import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import {
  addDays,
  billState,
  isYmd,
  localDayStartIso,
  longDate,
  money,
  orderTypeLabel,
  stateStyle,
  timeOnly,
  todayIn,
} from "@/lib/format";

const FILTERS = [
  { key: "all", label: "All" },
  { key: "unpaid", label: "Unpaid" },
  { key: "voided", label: "Voided" },
] as const;

export default async function BillsPage({
  searchParams,
}: {
  searchParams: Promise<{ date?: string; show?: string }>;
}) {
  const user = await requireUser();
  const sp = await searchParams;
  const tz = user.timezone;
  const today = todayIn(tz);
  const date = isYmd(sp.date) ? sp.date : today;
  const show = FILTERS.some((f) => f.key === sp.show) ? (sp.show as string) : "all";

  const supabase = await createClient();
  let q = supabase
    .from("orders")
    .select("id, bill_number, created_at, order_type, grand_total, paid_total, status, payment_status, dining_table_id, cashier_id, merged_into")
    .gte("created_at", localDayStartIso(date, tz))
    .lt("created_at", localDayStartIso(addDays(date, 1), tz))
    .order("created_at", { ascending: false })
    .limit(500);
  if (show === "unpaid") q = q.in("payment_status", ["unpaid", "partial"]).neq("status", "voided");
  if (show === "voided") q = q.eq("status", "voided").is("merged_into", null);
  const { data: orders } = await q;
  const rows = orders ?? [];

  const ids = rows.map((o) => o.id);
  const tableIds = [...new Set(rows.map((o) => o.dining_table_id).filter(Boolean))] as string[];
  const [{ data: payments }, { data: methods }, { data: tables }] = await Promise.all([
    ids.length
      ? supabase.from("payments").select("order_id, payment_method_id").in("order_id", ids)
      : Promise.resolve({ data: [] as { order_id: string; payment_method_id: string }[] }),
    supabase.from("payment_methods").select("id, name"),
    tableIds.length
      ? supabase.from("dining_tables").select("id, table_number").in("id", tableIds)
      : Promise.resolve({ data: [] as { id: string; table_number: string }[] }),
  ]);
  const methodName = new Map((methods ?? []).map((m) => [m.id, m.name]));
  const paidWith = new Map<string, string>();
  for (const p of payments ?? []) {
    const name = methodName.get(p.payment_method_id) ?? "";
    const prev = paidWith.get(p.order_id);
    paidWith.set(p.order_id, prev && !prev.split(" + ").includes(name) ? `${prev} + ${name}` : prev ?? name);
  }
  const tableNo = new Map((tables ?? []).map((t) => [t.id, t.table_number]));

  const live = rows.filter((o) => o.status !== "voided");
  const total = live.reduce((s, o) => s + Number(o.grand_total), 0);
  const unpaid = live.filter((o) => o.payment_status === "unpaid" || o.payment_status === "partial");

  const link = (d: string, s = show) => `/bills?date=${d}${s !== "all" ? `&show=${s}` : ""}`;

  return (
    <div className="mx-auto max-w-4xl">
      <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold tracking-tight">Bills</h1>
          <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            {longDate(date)}
            {date === today ? " · today" : ""}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Link href={link(addDays(date, -1))} className="btn border text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
            ← Prev
          </Link>
          <form action="/bills" className="flex items-center gap-2">
            <input type="date" name="date" defaultValue={date} max={today} className="field h-12 w-40 text-sm" />
            {show !== "all" && <input type="hidden" name="show" value={show} />}
            <button className="btn border text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
              Go
            </button>
          </form>
          {date < today && (
            <Link href={link(addDays(date, 1))} className="btn border text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
              Next →
            </Link>
          )}
        </div>
      </div>

      <div className="mb-4 grid grid-cols-3 gap-3">
        <Stat label="Bills" value={String(live.length)} />
        <Stat label="Total billed" value={money(total, user.currency_code)} />
        <Stat label="Unpaid" value={`${unpaid.length} · ${money(unpaid.reduce((s, o) => s + Number(o.grand_total) - Number(o.paid_total ?? 0), 0), user.currency_code)}`} warn={unpaid.length > 0} />
      </div>

      <div className="mb-3 flex gap-1.5">
        {FILTERS.map((f) => (
          <Link
            key={f.key}
            href={link(date, f.key)}
            className="rounded-full border px-3 py-1.5 text-xs font-semibold"
            style={{
              borderColor: show === f.key ? "var(--color-brand)" : "var(--color-line)",
              background: show === f.key ? "var(--color-brand-soft)" : "var(--color-surface)",
              color: show === f.key ? "var(--color-brand-strong)" : "var(--color-ink-2)",
            }}
          >
            {f.label}
          </Link>
        ))}
      </div>

      {rows.length === 0 ? (
        <div className="card p-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
          No bills {show === "all" ? "" : show + " "}on this day.
        </div>
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ color: "var(--color-ink-3)" }}>
                <th className="px-4 py-3 text-left text-xs font-semibold">Bill</th>
                <th className="px-4 py-3 text-left text-xs font-semibold">Time</th>
                <th className="px-4 py-3 text-left text-xs font-semibold">Type</th>
                <th className="px-4 py-3 text-left text-xs font-semibold">Paid by</th>
                <th className="px-4 py-3 text-right text-xs font-semibold">Total</th>
                <th className="px-4 py-3 text-left text-xs font-semibold">Status</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((o) => {
                const st = o.merged_into ? { label: "Merged", bg: "var(--color-ground)", fg: "var(--color-ink-3)" } : stateStyle[billState(o.status, o.payment_status)];
                return (
                  <tr key={o.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                    <td className="px-4 py-3 font-semibold">
                      <Link href={`/bills/${o.id}`} style={{ color: "var(--color-brand)" }}>
                        {o.bill_number}
                      </Link>
                    </td>
                    <td className="px-4 py-3 tabular-nums">{timeOnly(o.created_at, tz)}</td>
                    <td className="px-4 py-3">
                      {orderTypeLabel[o.order_type] ?? o.order_type}
                      {o.dining_table_id && tableNo.get(o.dining_table_id) ? ` · T${tableNo.get(o.dining_table_id)}` : ""}
                    </td>
                    <td className="px-4 py-3">{paidWith.get(o.id) || "—"}</td>
                    <td
                      className="px-4 py-3 text-right tabular-nums"
                      style={o.status === "voided" ? { textDecoration: "line-through", color: "var(--color-ink-3)" } : undefined}
                    >
                      {money(o.grand_total, user.currency_code)}
                    </td>
                    <td className="px-4 py-3">
                      <span className="rounded-full px-2 py-1 text-xs font-semibold" style={{ background: st.bg, color: st.fg }}>
                        {st.label}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value, warn }: { label: string; value: string; warn?: boolean }) {
  return (
    <div className="card p-3">
      <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
        {label}
      </div>
      <div className="mt-1 text-lg font-bold tabular-nums" style={warn ? { color: "var(--color-warn)" } : undefined}>
        {value}
      </div>
    </div>
  );
}
