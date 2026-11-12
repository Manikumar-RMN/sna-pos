import Link from "next/link";
import type { ReactNode } from "react";
import { longDate } from "@/lib/format";
import { rangeText } from "@/lib/report-shell";
import { CsvButton } from "../csv-button";
import { FilterForm, type FilterToggle } from "./filter-form";
import { OutletBanner } from "./outlet-banner";
import { PrintButton } from "./print-button";
import { PrintStamp } from "./print-stamp";
import type { ReportCtx } from "./report-context";
import { Notice } from "./ui";

export type ReportExcel = { filename: string; header: string[]; rows: (string | number)[][] };

/**
 * The frame every report page uses, in the style of the WinCloud report screens: a white panel with the report name
 * and a way back, the outlet line (with the outlet picker for people who have several outlets), the filter form
 * (From/To, quick presets, toggles, Display), Print, Excel (CSV) and Back buttons, then the report itself.
 * Printing hides the menus, filters and buttons and adds a header (business, report, outlet, dates, print time).
 *
 *   <ReportShell ctx={ctx} title="Popular items" basePath="/reports/popular-items"
 *     excel={rows.length ? { filename: `x_${from}_${to}.csv`, header: [...], rows } : null}>
 *     <ReportTable head={[...]} rows={...} total={["TOTAL", ...]} />
 *   </ReportShell>
 *
 * `toggles` adds on/off options to the filter form; read them back from searchParams (`name=1` means on).
 */
export function ReportShell({
  ctx,
  title,
  basePath,
  basis = "by business day · voided bills and cancelled items are left out",
  note,
  toggles,
  excel,
  landscape = false,
  children,
}: {
  ctx: ReportCtx;
  title: string;
  basePath: string;
  basis?: string;
  note?: string;
  toggles?: FilterToggle[];
  /** Data for the Excel (CSV) button; leave out or pass null when there is nothing to export. */
  excel?: ReportExcel | null;
  /** Print on A4 landscape (wide tables). Default is A4 portrait. */
  landscape?: boolean;
  children: ReactNode;
}) {
  const { from, to, user, scope } = ctx;
  const dates = rangeText(from, to, longDate);
  return (
    <div className={`report-root mx-auto ${landscape ? "max-w-[100rem] rpt-landscape" : "max-w-6xl"}`}>
      <section className="rpt-panel">
        <div className="rpt-titlebar">
          <h1>{title}</h1>
          <Link href="/reports" className="no-print rpt-back">
            ← Back to reports
          </Link>
        </div>

        {/* Printed pages only */}
        <div className="print-only rpt-printhead">
          <div className="rpt-printhead-biz">{user.trading_name}</div>
          <div className="rpt-printhead-title">{title}</div>
          <div>{scope.label}</div>
          <div>{dates}</div>
          <div>
            Printed: <PrintStamp timezone={user.timezone} />
          </div>
        </div>

        <p className="rpt-scope">
          <strong>{scope.label}</strong> · {dates} · {basis}
          {note ? ` · ${note}` : ""}
        </p>
        {(ctx.showPicker || scope.all) && (
          <div className="no-print">
            <OutletBanner scope={scope} info={ctx.info} showPicker={ctx.showPicker} />
          </div>
        )}

        <FilterForm basePath={basePath} from={from} to={to} range={ctx.range} max={ctx.today} toggles={toggles}>
          <PrintButton />
          {excel ? <CsvButton filename={excel.filename} header={excel.header} rows={excel.rows} label="Excel (CSV)" className="rpt-btn" /> : null}
        </FilterForm>

        {ctx.clamped && <Notice>Reports cover at most one year, so only the latest 366 days of the range you chose are shown.</Notice>}
        <div className="rpt-body">{children}</div>
      </section>
    </div>
  );
}
