import { can, has, requireUser } from "@/lib/auth";
import { rangeQuery } from "@/lib/reports-pack";
import { ReportList } from "./_components/report-list";

export default async function ReportsPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const user = await requireUser();
  if (!can(user, "report.view_sales")) {
    return (
      <div className="mx-auto max-w-md">
        <h1 className="text-xl font-bold tracking-tight">Reports</h1>
        <div className="card mt-4 p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Your role does not include viewing sales reports.
        </div>
      </div>
    );
  }
  const sp = await searchParams;
  // Inventory reports need the stock module and stock.view; customer reports need customer.view.
  const reportAccess = {
    financial: can(user, "report.view_financial"),
    stock: has(user, "stock") && (can(user, "stock.view") || can(user, "stock.manage")),
    customers: can(user, "customer.view"),
    loyalty: has(user, "loyalty") && can(user, "customer.view"),
    users: can(user, "user.manage"),
  };
  return (
    <div className="mx-auto max-w-6xl">
      <h1 className="text-xl font-bold tracking-tight">POS reports</h1>
      <p className="mt-1 mb-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
        Sales, operations, items and staff reports. Each opens with From and To dates, Display, Print and Excel.
      </p>
      <ReportList access={reportAccess} section="pos" keep={rangeQuery(sp)} />
    </div>
  );
}
