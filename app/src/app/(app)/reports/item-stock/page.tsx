import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { movementKindLabel } from "@/lib/reports-pack-4";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const STATUS: Record<string, string> = { ok: "In stock", low: "Low — time to order", out: "Out of stock", negative: "Negative — check receipts" };

export default async function ItemStockPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; item?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Item stock query", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, user } = ctx;
  const c = user.currency_code;
  const { data: ings } = await supabase.from("ingredients").select("id, name, unit").order("name");
  const item = sp.item && (ings ?? []).some((i) => i.id === sp.item) ? sp.item : null;
  let o: ReturnType<typeof asObj> | null = null;
  let err = null;
  if (item) {
    const { data, error } = await supabase.rpc("report_item_stock", { p_ingredient: item });
    err = reportRpcError(error);
    o = err ? null : asObj(data);
  }
  const unit = o ? s(o.unit) : "";
  const receipts = o ? asList(o.receipts) : [];
  const moves = o ? asList(o.movements) : [];
  return (
    <ReportShell ctx={ctx} title="Item stock query" basePath="/reports/item-stock" basis="right now · one ingredient at a glance" excel={null}>
      <form method="get" className="no-print mb-3 flex flex-wrap items-end gap-2 text-sm">
        <label className="block">
          <span className="mb-1 block text-xs font-semibold">Ingredient</span>
          <select name="item" defaultValue={item ?? ""} className="field h-10 text-sm">
            <option value="">Choose an ingredient…</option>
            {(ings ?? []).map((i) => (
              <option key={i.id} value={i.id}>
                {i.name} ({i.unit})
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="btn btn-primary px-4 text-sm">
          Show
        </button>
      </form>
      {!item ? <Empty text="Choose an ingredient to see its stock, last purchase and how long it will last." /> : err ? <Err e={err} /> : !o ? null : (
        <div className="space-y-5">
          <ReportTable
            head={["Ingredient", "On hand", "Cost each", "Stock value", "Reorder level", "Status"]}
            textCols={[0, 5]}
            rows={[[s(o.item), q(o.on_hand, unit), money(n(o.cost), c), money(n(o.value), c), n(o.reorder_level) > 0 ? q(o.reorder_level, unit) : "—", STATUS[s(o.status)] ?? s(o.status)]]}
          />
          <ReportTable
            head={["Used in last 30 days", "Average per day", "Lasts about", "Last used"]}
            textCols={[3]}
            rows={[[q(o.used_30, unit), q(o.daily_use, unit), o.days_cover === null || o.days_cover === undefined ? "—" : `${n(o.days_cover)} days`, s(o.last_used, "Never")]]}
          />
          <section>
            <h3 className="mb-2 text-sm font-bold">Last purchases</h3>
            {receipts.length === 0 ? <Empty text="Nothing bought yet." /> : (
              <ReportTable head={["Day", "Receipt", "Supplier", "Quantity", "Rate", "Value"]} textCols={[0, 1, 2]} rows={receipts.map((x) => [s(x.received_on), s(x.number), s(x.supplier), q(x.qty, unit), money(n(x.unit_cost), c), money(n(x.line_total), c)])} />
            )}
          </section>
          <section>
            <h3 className="mb-2 text-sm font-bold">Latest movements</h3>
            {moves.length === 0 ? <Empty text="No movements yet." /> : (
              <ReportTable head={["Day", "Type", "In", "Out", "Rate", "Reason"]} textCols={[0, 1, 5]} rows={moves.map((x) => [s(x.day), movementKindLabel(s(x.kind)), n(x.qty) > 0 ? q(x.qty, unit) : "", n(x.qty) < 0 ? q(-n(x.qty), unit) : "", money(n(x.rate), c), s(x.reason, "—")])} />
            )}
          </section>
          <Note>This is the stock now, for this outlet. For a full history over dates, open Stock ledger.</Note>
        </div>
      )}
    </ReportShell>
  );
}
