import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, q, s } from "@/lib/inv-report";
import { movementKindLabel } from "@/lib/reports-pack-4";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function StockLedgerPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; item?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Stock ledger", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;
  const { data: ings } = await supabase.from("ingredients").select("id, name, unit").order("name");
  const item = sp.item && (ings ?? []).some((i) => i.id === sp.item) ? sp.item : null;
  let led: ReturnType<typeof asObj> | null = null;
  let err = null;
  if (item) {
    const { data, error } = await supabase.rpc("report_stock_ledger", { p_ingredient: item, p_from: from, p_to: to });
    err = reportRpcError(error);
    led = err ? null : asObj(data);
  }
  const rows = led ? asList(led.rows) : [];
  const unit = led ? s(led.unit) : "";
  const head = ["Day", "Type", "Receipt", "Issue", "Rate", "Value", "Balance", "Reason / note"];
  const cells = rows.map((x) => {
    const qty = n(x.qty);
    return [s(x.day), movementKindLabel(s(x.kind)), qty > 0 ? q(qty, unit) : "", qty < 0 ? q(-qty, unit) : "", money(n(x.rate), c), money(n(x.value), c), q(x.balance, unit), [s(x.reason), s(x.note)].filter(Boolean).join(" - ") || "—"];
  });
  return (
    <ReportShell
      ctx={ctx}
      title="Stock ledger"
      basePath="/reports/stock-ledger"
      basis="by business day · every in and out of one ingredient with a running balance"
      landscape
      excel={led && rows.length > 0 ? { filename: `stock_ledger_${from}_${to}.csv`, header: head, rows: cells } : null}
    >
      <form method="get" className="no-print mb-3 flex flex-wrap items-end gap-2 text-sm">
        <input type="hidden" name="from" value={from} />
        <input type="hidden" name="to" value={to} />
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
          Show ledger
        </button>
      </form>
      {!item ? <Empty text="Choose an ingredient to see its ledger." /> : err ? <Err e={err} /> : !led ? null : (
        <>
          <ReportTable
            head={["Ingredient", "Opening", "Received", "Issued or used", "Closing"]}
            textCols={[0]}
            rows={[[s(led.item), q(led.opening, unit), q(led.receipts, unit), q(led.issues, unit), q(led.closing, unit)]]}
          />
          <div className="mt-4">
            {rows.length === 0 ? <Empty text="No movements in this period." /> : <ReportTable head={head} textCols={[0, 1, 7]} rows={cells} />}
          </div>
          <Note>Opening is the stock at the start of the first day. Balance runs down the list. Rate is the cost when the movement happened.</Note>
        </>
      )}
    </ReportShell>
  );
}
