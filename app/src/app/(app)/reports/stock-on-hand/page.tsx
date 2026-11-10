import { reportRpcError } from "@/lib/reports-pack";
import { STOCK_STATUS_LABEL, attentionOnly, parseStockOnHand, qtyText, unitLabel, type StockRow } from "@/lib/reports-pack-4";
import { longDate, money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function StockOnHandPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; attention?: string; general?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Stock on hand", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, to, today, scope, user } = ctx;
  const c = user.currency_code;
  const onlyAttention = sp.attention === "1";
  const onlyGeneral = sp.general === "1";
  const { data: typeRows } = await supabase.from("ingredients").select("id, item_type");
  const isGeneral = new Set((typeRows ?? []).filter((t) => t.item_type === "general").map((t) => t.id));

  // Stock is a balance, so only the To date matters: it is the "as of" business day. Today (or later) means right now.
  const asOf = to >= today ? null : to;
  const { data, error } = await supabase.rpc("report_stock_on_hand", { p_as_of: asOf });
  const err = reportRpcError(error);
  const rep = err ? null : parseStockOnHand(data as unknown);
  const byType = rep ? (onlyGeneral ? rep.rows.filter((x) => isGeneral.has(x.ingredientId)) : rep.rows) : [];
  const rows = onlyAttention ? attentionOnly(byType) : byType;
  const t = rep?.totals;
  const m = (n: number | null) => (n === null ? "—" : money(n, c));

  const head = [...(scope.all ? ["Outlet"] : []), "Item", "Type", "Category", "On hand", "Cost per unit", "Value", "Reorder at", "Status"];
  const textCols = scope.all ? [0, 1, 2, 3, 8] : [0, 1, 2, 7];
  const cells = (x: StockRow) => [
    ...(scope.all ? [x.outletName] : []),
    x.name,
    isGeneral.has(x.ingredientId) ? "General" : "Food",
    x.category || "—",
    <span key="q" style={x.status === "negative" ? { color: "var(--color-bad)", fontWeight: 700 } : undefined}>{qtyText(x.onHand, x.unit)}</span>,
    x.cost === null ? "—" : `${m(x.cost)} / ${unitLabel(x.unit)}`,
    m(x.value),
    x.reorderLevel === null ? "—" : qtyText(x.reorderLevel, x.unit),
    <span key="s" style={x.status === "ok" ? undefined : { color: x.status === "low" ? "var(--color-warn)" : "var(--color-bad)", fontWeight: 700 }}>{STOCK_STATUS_LABEL[x.status]}</span>,
  ];
  const sum = {
    items: rows.length,
    value: rows.reduce((a, x) => a + (x.value ?? 0), 0),
    low: rows.filter((x) => x.status === "low").length,
    out: rows.filter((x) => x.status === "out").length,
    negative: rows.filter((x) => x.status === "negative").length,
  };
  const total = t ? [...(scope.all ? [""] : []), "TOTAL", "", "", `${sum.items} items`, "", m(sum.value), "", `${sum.low} low · ${sum.out} out · ${sum.negative} negative`] : [];

  const csv = rows.map((x) => [
    ...(scope.all ? [x.outletName] : []),
    x.name,
    isGeneral.has(x.ingredientId) ? "General" : "Food",
    x.category,
    x.onHand,
    x.unit,
    x.cost ?? "",
    x.value ?? "",
    x.reorderLevel ?? "",
    STOCK_STATUS_LABEL[x.status],
  ]);

  return (
    <ReportShell
      ctx={ctx}
      title="Stock on hand"
      basePath="/reports/stock-on-hand"
      basis={asOf ? `as of the end of business day ${longDate(asOf)} · the From date is not used` : "right now · choose an earlier To date to see a past day"}
      landscape
      toggles={[{ name: "attention", label: "Only low, out and negative", checked: onlyAttention }, { name: "general", label: "General items only (pens, notebooks…)", checked: onlyGeneral }]}
      excel={rows.length > 0 ? { filename: `stock_on_hand_${asOf ?? today}.csv`, header: [...(scope.all ? ["Outlet"] : []), "Item", "Type", "Category", "On hand", "Unit", "Cost per unit", "Value", "Reorder at", "Status"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || rep.rows.length === 0 ? <Empty text="No items in stock records yet." /> : rows.length === 0 ? <Empty text="Nothing is low, out or negative." /> : (
          <>
            <p className="text-sm">
              Stock worth <b>{m(sum.value)}</b> across {sum.items} item{sum.items === 1 ? "" : "s"}.
              {sum.negative > 0 ? <> <b style={{ color: "var(--color-bad)" }}>{sum.negative} below zero.</b></> : null}
            </p>
            <ReportTable head={head} textCols={textCols} total={total} rows={rows.map(cells)} />
            <Note>
              Value is the quantity on hand times the current average cost per unit (the Stock ledger adds up each movement at its own day's cost, so the two can differ when prices have changed). Ingredients below zero are valued at 0 and counted
              separately: a negative balance means more was used than was recorded as bought, so check purchases and the recipes.
              {scope.all ? " Each outlet keeps its own stock, so an ingredient has one row per outlet." : ""}
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
