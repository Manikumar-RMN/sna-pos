import Link from "next/link";
import { reportRpcError } from "@/lib/reports-pack";
import { parseLeakage } from "@/lib/reports-pack-4";
import { money } from "@/lib/format";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

const DETAIL: Record<string, { href: string; text: string }> = {
  void_bills: { href: "/reports/void-bills", text: "Void bills" },
  cancelled_items: { href: "/reports/audit", text: "Voids, cancels and refunds" },
  credit_notes: { href: "/reports/audit", text: "Voids, cancels and refunds" },
  discounts: { href: "/reports/discounts", text: "Discounts" },
  reprints: { href: "/reports/reprints", text: "Reprints" },
};

export default async function LeakageReportPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Leakage summary" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_leakage", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const rep = err ? null : parseLeakage(data as unknown);
  const any = !!rep && (rep.summary.some((s) => s.count > 0) || rep.byStaff.length > 0);

  const csv: (string | number)[][] = [];
  if (rep) {
    for (const s of rep.summary) csv.push(["Summary", s.label, s.count, s.value ?? ""]);
    for (const s of rep.byStaff) csv.push(["Staff", s.staffName, s.voids, s.cancelledItems, s.cancelledKots, s.creditNotes, s.complimentary, s.reprints, s.moves]);
  }

  return (
    <ReportShell
      ctx={ctx}
      title="Leakage summary"
      basePath="/reports/leakage"
      basis="voids, cancels, credit notes, discounts, free meals, reprints and moves · by business day"
      excel={rep && csv.length > 0 ? { filename: `leakage_${from}_${to}.csv`, header: ["Group", "Name", "Count / Voids", "Value / Cancelled items", "Cancelled KOTs", "Credit notes", "Complimentary", "Reprints", "Moves"], rows: csv } : null}
    >
      <div className="space-y-6">
        {err ? <Err e={err} /> : !rep || !any ? <Empty text="Nothing to show for this period: no voids, cancels, credit notes, discounts, free meals, reprints or moves." /> : (
          <>
            <section>
              <h3 className="mb-2 text-sm font-bold">What happened</h3>
              <ReportTable
                head={["What", "Times", ...(rep.money ? ["Value"] : []), "Details"]}
                textCols={[0, rep.money ? 3 : 2]}
                rows={rep.summary.map((s) => [
                  s.label,
                  String(s.count),
                  ...(rep.money ? [s.value === null ? "—" : money(s.value, c)] : []),
                  DETAIL[s.key] ? (
                    <Link key={s.key} href={`${DETAIL[s.key].href}?from=${from}&to=${to}&range=custom`} className="underline">{DETAIL[s.key].text}</Link>
                  ) : "—",
                ])}
              />
            </section>

            <section>
              <h3 className="mb-2 text-sm font-bold">By staff member</h3>
              <ReportTable
                head={["Staff", "Voids", "Cancelled items", "Cancelled KOTs", "Credit notes", "Complimentary", "Reprints", "Moves"]}
                textCols={[0]}
                rows={rep.byStaff.map((s) => [s.staffName, String(s.voids), String(s.cancelledItems), String(s.cancelledKots), String(s.creditNotes), String(s.complimentary), String(s.reprints), String(s.moves)])}
              />
            </section>

            <Note>
              A high number is not proof of wrongdoing: it is a place to look. Staff counts come from the audit log, so they show who did each action.
              {rep.money ? "" : " Rupee values are shown only to people with the financial reports right."}
              {" "}Value for a complimentary bill or staff meal is the food value before tax; for a discount it is the discount given.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
