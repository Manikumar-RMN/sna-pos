import { friendlyDbError, type DbErrorLike } from "@/lib/db-error";

export function Card({ title, action, children }: { title: string; action?: React.ReactNode; children: React.ReactNode }) {
  return (
    <section className="card p-4">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="text-sm font-bold">{title}</h2>
        {action}
      </div>
      {children}
    </section>
  );
}

/** Columns in `textCols` are left-aligned text; the rest are right-aligned numbers. */
export function Table({ head, rows, textCols = [0] }: { head: string[]; rows: string[][]; textCols?: number[] }) {
  return (
    <div className="max-h-[32rem] overflow-auto">
      <table className="w-full text-sm">
        <thead>
          <tr style={{ color: "var(--color-ink-3)" }}>
            {head.map((h, i) => (
              <th key={h} className={`pb-2 pr-2 text-xs font-semibold ${textCols.includes(i) ? "text-left" : "text-right"}`}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={i} style={{ borderTop: "1px solid var(--color-line)" }}>
              {r.map((cell, j) => (
                <td key={j} className={`py-1.5 pr-2 ${textCols.includes(j) ? "text-left" : "text-right tabular-nums"}`}>
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Empty({ text }: { text: string }) {
  return (
    <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
      {text}
    </p>
  );
}

export function Note({ children }: { children: React.ReactNode }) {
  return (
    <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
      {children}
    </p>
  );
}

export function Err({ e }: { e: DbErrorLike }) {
  return (
    <p className="text-sm" style={{ color: "var(--color-bad)" }}>
      {friendlyDbError(e)}
    </p>
  );
}

/** A boxed message above the report: warning (default) or error. */
export function Notice({ tone = "warn", children }: { tone?: "warn" | "bad"; children: React.ReactNode }) {
  return (
    <div className="card mb-4 p-3 text-xs" style={{ color: tone === "bad" ? "var(--color-bad)" : "var(--color-warn)" }}>
      {children}
    </div>
  );
}
