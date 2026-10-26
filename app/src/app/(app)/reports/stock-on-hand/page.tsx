import { reportRpcError } from "@/lib/reports-pack";
import { STOCK_STATUS_LABEL, attentionOnly, parseStockOnHand, qtyText, unitLabel, type StockRow } from "@/lib/reports-pack-4";
import { longDate, money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function StockOnHandPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; attention?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Stock on hand", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, to, today, scope, user } = ctx;
  const c = user.currency_code;
  const onlyAttention = sp.attention === "1";

  // Stock is a balance, so only the To date matters: it is the "as of" business day. Today (or later) means right now.
  const asOf = to >= today ? null : to;
  const { data, error } = await supabase.rpc("report_stock_on_hand", { p_as_of: asOf });
  const err = reportRpcError(error);
  const rep = err ? null : parseStockOnHand(data as unknown);
  const rows = rep ? (onlyAttention ? attentionOnly(rep.rows) : rep.rows) : [];
  const t = rep?.totals;
  const m = (n: number | null) => (n === null ? "—" : money(n, c));

  const head = [...(scope.all ? ["Outlet"] : []), "Ingredient", "Category", "On hand", "Cost per unit", "Value", "Reorder at", "Status"];
  const textCols = scope.all ? [0, 1, 2, 7] : [0, 1, 6];
  const cells = (x: StockRow) => [
    ...(scope.all ? [x.outletName] : []),
    x.name,
    x.category || "—",
    <span key="q" style={x.status === "negative" ? { color: "var(--color-bad)", fontWeight: 700 } : undefined}>{qtyText(x.onHand, x.unit)}</span>,
    x.cost === null ? "—" : `${m(x.cost)} / ${unitLabel(x.unit)}`,
    m(x.value),
    x.reorderLevel === null ? "—" : qtyText(x.reorderLevel, x.unit),
    <span key="s" style={x.status === "ok" ? undefined : { color: x.status === "low" ? "var(--color-warn)" : "var(--color-bad)", fontWeight: 700 }}>{STOCK_STATUS_LABEL[x.status]}</span>,
  ];
  const total = t ? [...(scope.all ? [""] : []), "TOTAL", "", `${t.items} items`, "", m(t.value), "", `${t.low} low · ${t.out} out · ${t.negative} negative`] : [];

  const csv = rows.map((x) => [
    ...(scope.all ? [x.outletName] : []),
    x.name,
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
      toggles={[{ name: "attention", label: "Only low, out and negative", checked: onlyAttention }]}
      excel={rows.length > 0 ? { filename: `stock_on_hand_${asOf ?? today}.csv`, header: [...(scope.all ? ["Outlet"] : []), "Ingredient", "Category", "On hand", "Unit", "Cost per unit", "Value", "Reorder at", "Status"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || rep.rows.length === 0 ? <Empty text="No ingredients in stock records yet." /> : rows.length === 0 ? <Empty text="Nothing is low, out or negative." /> : (
          <>
            <p className="text-sm">
              Stock worth <b>{m(t?.value ?? 0)}</b> across {rep.totals.items} ingredient{rep.totals.items === 1 ? "" : "s"}.
              {rep.totals.negative > 0 ? <> <b style={{ color: "var(--color-bad)" }}>{rep.totals.negative} below zero.</b></> : null}
            </p>
            <ReportTable head={head} textCols={textCols} total={total} rows={rows.map(cells)} />
            <Note>
              Value is the quantity on hand times the current cost per unit. Ingredients below zero are valued at 0 and counted
              separately: a negative balance means more was used than was recorded as bought, so check purchases and the recipes.
              {scope.all ? " Each outlet keeps its own stock, so an ingredient has one row per outlet." : ""}
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
