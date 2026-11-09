import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { rangeQuery } from "@/lib/reports-pack";
import { ReportList } from "../../_components/report-list";
import { REPORT_SECTIONS, type SectionKey } from "../../_components/report-links";

/** One report section: Purchase and inventory reports, Loyalty reports or Audit reports. POS reports is the Reports home page. */
export default async function ReportSectionPage({
  params,
  searchParams,
}: {
  params: Promise<{ key: string }>;
  searchParams: Promise<{ range?: string; from?: string; to?: string }>;
}) {
  const { key } = await params;
  const section = REPORT_SECTIONS.find((s) => s.key === key && s.key !== "pos");
  if (!section) notFound();
  const user = await requireUser();
  if (!can(user, "report.view_sales")) {
    return (
      <div className="mx-auto max-w-6xl">
        <h1 className="text-xl font-bold tracking-tight">{section.title}</h1>
        <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Your role does not include viewing sales reports.
        </div>
      </div>
    );
  }
  const access = {
    financial: can(user, "report.view_financial"),
    stock: has(user, "stock") && (can(user, "stock.view") || can(user, "stock.manage")),
    customers: can(user, "customer.view"),
    loyalty: has(user, "loyalty") && can(user, "customer.view"),
  };
  const keep = rangeQuery(await searchParams);
  return (
    <div className="mx-auto max-w-6xl">
      <h1 className="text-xl font-bold tracking-tight">{section.title}</h1>
      <p className="mt-1 mb-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Pick a report. Each opens with From and To dates, Display, Print and Excel.
      </p>
      <ReportList access={access} section={section.key as SectionKey} keep={keep} />
    </div>
  );
}
