"use client";

import Link from "next/link";
import { useState, type FormEvent, type ReactNode } from "react";
import { REPORT_PRESETS, presetHref, validateDateRange } from "@/lib/report-shell";

export type FilterToggle = { name: string; label: string; checked: boolean };

/**
 * The filter form at the top of a report: From and To dates, quick presets as small links, optional on/off toggles
 * (e.g. "Include pending KOT"), and the Display button. Display opens `basePath?from=&to=` plus each switched-on toggle
 * as `name=1`. Buttons that belong next to Display (Print, Excel, Back) come in as `children`.
 */
export function FilterForm({
  basePath,
  from,
  to,
  range,
  max,
  toggles = [],
  children,
}: {
  basePath: string;
  from: string;
  to: string;
  /** The preset in use ("today", "7d", ... or "custom"), so it can be shown as chosen. */
  range: string;
  /** The latest date that can be chosen (the business day being counted to). */
  max: string;
  toggles?: FilterToggle[];
  children?: ReactNode;
}) {
  const [error, setError] = useState<string | null>(null);
  const extra: Record<string, string> = {};
  for (const t of toggles) if (t.checked) extra[t.name] = "1";

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    const fd = new FormData(e.currentTarget);
    const problem = validateDateRange(String(fd.get("from") ?? ""), String(fd.get("to") ?? ""), max);
    if (problem) {
      e.preventDefault();
      setError(problem);
    } else {
      setError(null);
    }
  }

  return (
    <form action={basePath} method="get" onSubmit={onSubmit} noValidate className="rpt-filter no-print">
      <div className="rpt-filter-row">
        <label className="rpt-field">
          <span>From date</span>
          <input type="date" name="from" defaultValue={from} max={max} required className="field" />
        </label>
        <label className="rpt-field">
          <span>To date</span>
          <input type="date" name="to" defaultValue={to} max={max} required className="field" />
        </label>
        {toggles.map((t) => (
          <label key={t.name} className="rpt-check">
            <input type="checkbox" name={t.name} value="1" defaultChecked={t.checked} />
            <span>{t.label}</span>
          </label>
        ))}
        <div className="rpt-buttons">
          <button type="submit" className="rpt-btn rpt-btn-main">
            Display
          </button>
          {children}
        </div>
      </div>
      <div className="rpt-presets" aria-label="Quick date ranges">
        {REPORT_PRESETS.map((p) => (
          <Link key={p.key} href={presetHref(basePath, p.key, extra)} className={range === p.key ? "is-on" : undefined} aria-current={range === p.key ? "true" : undefined}>
            {p.label}
          </Link>
        ))}
      </div>
      {error && (
        <p role="alert" className="rpt-error">
          {error}
        </p>
      )}
    </form>
  );
}
