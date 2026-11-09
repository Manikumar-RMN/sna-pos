import { money, longDate } from "@/lib/format";
import { reportRpcError } from "@/lib/reports-pack";
import { csvWithFooter, parseBook } from "@/lib/reports-pack-2";
import { Empty, Err, Note } from "../_components/ui";
import { loadReport } from "../_components/report-context";
import { ReportShell } from "../_components/report-shell";
import { ReportTable } from "../_components/report-table";

export default async function SalesDayBookPage({ searchParams }: { searchParams: Promise<{ range?: string; from?: string; to?: string }> }) {
  const r = await loadReport(await searchParams, { title: "Sales day book", need: "financial" });
  if (!r.ok) return r.denied;
  const { ctx } = r;
  const { supabase, from, to, scope, user } = ctx;
  const c = user.currency_code;

  const { data, error } = await supabase.rpc("report_sales_day_book", { p_from: from, p_to: to });
  const err = reportRpcError(error);
  const { rows, totals } = parseBook(err ? null : (data as unknown), "business_date");

  const head = ["Date", "Bills", "Complimentary", "Gross", "Discount", "Service", "Tax", "Rounding", "Net sales", "Total billed", "Credit notes", "Net billed", "Cash", "Other modes", "Unpaid"];
  type Row = (typeof rows)[number];
  const nums = (b: Row) => [b.bills, b.compBills, b.gross, b.discount, b.serviceCharge, b.tax, b.rounding, b.netSales, b.grandTotal, -b.credit, b.grandTotal - b.credit, b.cash, b.nonCash, b.unpaid];
  const show = (b: Row) => [...nums(b).slice(0, 2).map(String), ...nums(b).slice(2).map((n) => money(n, c))];
  const lead = (b: Row): string[] => [longDate(b.key)];

  return (
    <ReportShell
      ctx={ctx}
      title="Sales day book"
      basePath="/reports/sales-day-book"
      basis="finished bills · by business day"
      landscape
      excel={rows.length > 0 ? { filename: `sales_day_book_${from}_${to}.csv`, header: head, rows: csvWithFooter(head.length, rows.map((b) => [...lead(b), ...nums(b)]), ["TOTAL", ...nums(totals)], null) } : null}
    >
      <div>
        {err ? <Err e={err} /> : rows.length === 0 ? <Empty text="No sales in this period." /> : (
          <>

            <ReportTable
              head={head}
              textCols={[0]}
              zebra
              rows={rows.map((b) => [...lead(b), ...show(b)])}
              total={["TOTAL", ...show(totals)]}
            />
            {scope.all && <Note>Totals combine all outlets. Pick one outlet to see its own book.</Note>}
            <Note>
              Bills, Gross and Discount leave out complimentary and staff-meal bills (counted under Complimentary). Service, Tax, Rounding and Total billed cover every finished bill. Net sales is the item value after discounts. Other modes is every payment that is not cash. Unpaid is what finished bills still owe.
            </Note>
          </>
        )}
      </div>
    </ReportShell>
  );
}
