import Link from "next/link";
import { reportRpcError } from "@/lib/reports-pack";
import { asList, asObj, n, s } from "@/lib/inv-report";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const LABEL: Record<string, string> = { expired: "Expired", soon: "Expiring soon", ok: "Fine" };

/** Expiry item list (as Winsar's "Expiry Item List"): batches still on the shelf, soonest expiry first. Shows the outlet you are working in. */
export default async function ExpiryReportPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string; days?: string }> }) {
  const sp = await searchParams;
  const r = await loadReport(sp, { title: "Expiry item list", need: "stock" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, user } = ctx;
  const c = user.currency_code;
  const days = [7, 14, 30, 60, 90].includes(Number(sp.days)) ? Number(sp.days) : 30;
  const { data, error } = await supabase.rpc("expiry_report", { p_days: days });
  const err = reportRpcError(error);
  const rows = err ? [] : asList(asObj(data).items);
  const head = ["Item", "Batch", "Receipt", "Received", "Best before", "Days left", "On shelf", "Value", "Status"];
  const cells = rows.map((x) => [s(x.ingredient), s(x.batch_no, "—"), s(x.receipt), s(x.received_on), s(x.expiry_date), String(n(x.days_left)), `${n(x.remaining)} ${s(x.unit, "")}`.trim(), money(n(x.value), c), LABEL[s(x.status)] ?? s(x.status)]);
  const sumBy = (st: string) => rows.filter((x) => s(x.status) === st).reduce((a, x) => a + n(x.value), 0);
  return (
    <ReportShell
      ctx={ctx}
      title="Expiry item list"
      basePath="/reports/expiry"
      basis={`batches on the shelf · expiring within ${days} days · this outlet`}
      excel={rows.length > 0 ? { filename: `expiry_${days}d.csv`, header: head, rows: rows.map((x) => [s(x.ingredient), s(x.batch_no), s(x.receipt), s(x.received_on), s(x.expiry_date), n(x.days_left), n(x.remaining), s(x.unit), n(x.value), LABEL[s(x.status)] ?? s(x.status)]) } : null}
    >
      <div className="no-print mb-3 flex flex-wrap items-center gap-2 text-sm">
        <span className="font-semibold">Expiring within:</span>
        {[7, 14, 30, 60, 90].map((d) => (
          <Link key={d} href={`?days=${d}`} className="rounded-lg border px-2.5 py-1 font-semibold" style={{ borderColor: d === days ? "var(--color-brand)" : "var(--color-line)", color: d === days ? "var(--color-brand)" : undefined }}>
            {d} days
          </Link>
        ))}
      </div>
      {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No batch with an expiry date is on the shelf." /> : (
        <>
          <ReportTable
            head={head}
            textCols={[0, 1, 2, 3, 4, 8]}
            zebra
            rows={cells}
            total={[`TOTAL (${rows.length})`, "", "", "", "", "", "", money(rows.reduce((a, x) => a + n(x.value), 0), c), ""]}
          />
          <Note>
            Expired but still on the shelf: {money(sumBy("expired"), c)}. Expiring within {days} days: {money(sumBy("soon"), c)}. The stock you hold is counted as the newest deliveries (first in, first out). Enter a batch number and best-before date when goods are received. This list shows the outlet you are working in.
          </Note>
        </>
      )}
    </ReportShell>
  );
}
