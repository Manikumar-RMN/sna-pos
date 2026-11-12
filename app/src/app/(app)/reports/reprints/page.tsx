import { reportRpcError } from "@/lib/reports-pack";
import { parseReprints, plural } from "@/lib/reports-pack-3";
import { truncationNote } from "@/lib/reports-pack-2";
import { dateTime } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function ReprintsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Reprints" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;

  // Reprints are the audit rows "bill.reprint" and "kot.reprint". The first print of a bill or ticket is not a reprint and is not listed.
  const { data, error } = await supabase.rpc("report_reprints", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseReprints(data as unknown);
  const rows = rep?.rows ?? [];
  const cut = rep ? truncationNote(rep.cap, "reprints") : null;

  const head = ["When", "What", "Bill", "Table", "By", ...(scope.all ? ["Outlet"] : []), "Detail"];
  const line = (x: (typeof rows)[number]) => [
    dateTime(x.at ?? "", user.timezone),
    x.kind === "kot" ? "Kitchen ticket" : "Bill",
    x.billNumber ?? "—",
    x.table ?? "—",
    x.userName,
    ...(scope.all ? [x.outletName] : []),
    x.detail || "—",
  ];
  const totalLabel = rep ? `TOTAL (${plural(rep.totals.reprints, "reprint")})` : "TOTAL";

  return (
    <ReportShell
      ctx={ctx}
      title="Reprints"
      basePath="/reports/reprints"
      basis="bill and kitchen-ticket reprints · newest first"
      landscape={scope.all}
      excel={
        rows.length > 0 && rep
          ? { filename: `reprints_${from}_${to}.csv`, header: head, rows: [...rows.map(line), [totalLabel, ...Array<string>(head.length - 1).fill("")], ...(cut ? [[`Truncated: showing first ${rep.cap.rowLimit} of ${rep.cap.totalRows}`, ...Array<string>(head.length - 1).fill("")]] : [])] }
          : null
      }
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || rows.length === 0 ? <Empty text="No reprints in this period." /> : (
          <>
            {cut && <Note>{cut}</Note>}
            <section>
              <h3 className="mb-2 text-sm font-bold">By person</h3>
              <ReportTable
                head={["Person", "Bill reprints", "Kitchen ticket reprints"]}
                textCols={[0]}
                total={["TOTAL", String(rep.totals.bills), String(rep.totals.kots)]}
                rows={rep.byUser.map((u) => [u.userName, String(u.bills), String(u.kots)])}
              />
            </section>
            <section>
              <h3 className="mb-2 text-sm font-bold">Every reprint</h3>
              <ReportTable
                groupBy={scope.all ? { col: head.indexOf("Outlet"), sums: {} } : undefined}
                head={head}
                textCols={head.map((_, i) => i)}
                zebra
                total={[totalLabel, ...Array<string>(head.length - 1).fill("")]}
                rows={rows.map(line)}
              />
            </section>
            <Note>
              A reprint is a second or later print of a bill or kitchen ticket. Prints from the browser menu (Ctrl+P) and from receipts made offline are recorded too: a Ctrl+P print is marked as declared because it cannot be held back, and an offline print appears once its bill has reached the server (it can show up a little later than it happened). A print that needs a manager PIN is listed only after the PIN is entered.
              The totals cover every reprint in the period{cut ? ", not only the rows shown" : ""}.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
