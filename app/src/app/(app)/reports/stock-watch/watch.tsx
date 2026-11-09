import Link from "next/link";
import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

type Sp = { range?: string; from?: string; to?: string; days?: string; cutoff?: string };
const KIND = {
  non_moving: { title: "Non-moving stock", path: "/reports/non-moving", basis: "stock that has not been used for the chosen number of days", empty: "Nothing is sitting unused for that long.", note: "Used means sold in a dish, thrown away, moved out or issued. An ingredient that was never used shows a dash." },
  high_value: { title: "High-value stock", path: "/reports/high-value-stock", basis: "stock worth at least the amount you choose", empty: "No stock is worth that much.", note: "Value is the quantity in stock times the current cost." },
  abc: { title: "ABC consumption", path: "/reports/abc-consumption", basis: "what was used over the chosen days, ranked by value", empty: "Nothing was used in that time.", note: "A is the few items that make up 70% of the value used. B is the next 20%. C is the rest." },
} as const;

/** The three Winsar watch-list reports share one table; days and cut-off come from the address. */
export async function WatchReport({ kind, searchParams }: { kind: keyof typeof KIND; searchParams: Promise<Sp> }) {
  const sp = await searchParams;
  const k = KIND[kind];
  const r = await loadReport(sp, { title: k.title, need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, user } = ctx;
  const c = user.currency_code;
  const days = Math.min(730, Math.max(1, Math.round(Number(sp.days) || (kind === "abc" ? 30 : 60))));
  const cutoff = Math.max(0, Number(sp.cutoff) || 1000);
  const { data, error } = await supabase.rpc("report_stock_watch", { p_kind: kind, p_days: days, p_cutoff: cutoff });
  const err = reportRpcError(error);
  const o = asObj(data);
  const rows = err ? [] : asList(o.rows);
  const t = asObj(o.totals);
  const head =
    kind === "non_moving" ? ["Item", "In stock", "Cost", "Value", "Last used", "Days idle"]
    : kind === "high_value" ? ["Item", "In stock", "Cost", "Value"]
    : ["Class", "Item", "Value used", "In stock"];
  const cells = rows.map((x) =>
    kind === "non_moving" ? [s(x.name), q(x.qty, x.unit), money(n(x.rate), c), money(n(x.value), c), s(x.last_used, "—"), x.days_idle == null ? "—" : String(n(x.days_idle))]
    : kind === "high_value" ? [s(x.name), q(x.qty, x.unit), money(n(x.rate), c), money(n(x.value), c)]
    : [s(x.class), s(x.name), money(n(x.used_value), c), q(x.qty, x.unit)],
  );
  const presets = kind === "high_value" ? [500, 1000, 5000, 10000] : [7, 30, 60, 90];
  const qs = (v: number) => `?${new URLSearchParams({ ...(sp.range ? { range: sp.range } : {}), [kind === "high_value" ? "cutoff" : "days"]: String(v) }).toString()}`;
  const cur = kind === "high_value" ? cutoff : days;
  return (
    <ReportShell ctx={ctx} title={k.title} basePath={k.path} basis={k.basis} excel={rows.length > 0 ? { filename: `${kind}.csv`, header: head, rows: cells } : null}>
      <div className="no-print mb-3 flex flex-wrap items-center gap-2 text-sm">
        <span className="font-semibold">{kind === "high_value" ? "Worth at least" : "Days"}:</span>
        {presets.map((v) => (
          <Link key={v} href={qs(v)} className="rounded-lg border px-2.5 py-1 font-semibold" style={{ borderColor: cur === v ? "var(--color-brand)" : "var(--color-line)", color: cur === v ? "var(--color-brand)" : undefined }}>
            {kind === "high_value" ? money(v, c) : v}
          </Link>
        ))}
      </div>
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text={k.empty} /> : (
        <>
          <ReportTable head={head} textCols={kind === "abc" ? [0, 1] : [0]} rows={cells} />
          <Note>{kind === "non_moving" ? `${n(t.items)} items, ${money(n(t.value), c)} in stock.` : kind === "high_value" ? `${n(t.items)} items, ${money(n(t.value), c)} in stock.` : `${n(t.items)} items used, ${money(n(t.used_value), c)} in total.`} {k.note}</Note>
        </>
      )}
    </ReportShell>
  );
}
