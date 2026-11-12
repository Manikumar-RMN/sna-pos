import type { ReactNode } from "react";

/**
 * A plain bordered report table: dense rows, a header that stays in view while the table scrolls, numbers
 * right-aligned, and an optional highlighted TOTAL row at the bottom. On a phone it scrolls sideways inside its panel.
 *
 * `rows` and `total` are cells already formatted as text. `total` lines up with `head`, e.g.
 * ["TOTAL", "120", "₹4,500.00"]. Columns listed in `textCols` are left-aligned text, the rest are numbers.
 *
 * `groupBy` splits the rows by the text in column `col` (for example the Outlet column when several outlets are in view): each group gets a
 * heading row, its rows, and, when `subtotal` is given, a subtotal row. `subtotal` receives the original row numbers of that group and
 * returns cells lined up with `head`. The TOTAL row at the bottom stays the grand total.
 */
export function ReportTable({
  head,
  rows,
  total,
  textCols = [0],
  zebra = false,
  groupBy,
}: {
  head: string[];
  rows: ReactNode[][];
  total?: ReactNode[];
  textCols?: number[];
  zebra?: boolean;
  groupBy?: { col: number; subtotal?: (rowNumbers: number[]) => ReactNode[] };
}) {
  const align = (i: number) => (textCols.includes(i) ? "text-left" : "text-right");
  return (
    <div className="rpt-scroll">
      <table className={`rpt-table${zebra ? " rpt-zebra" : ""}`}>
        <thead>
          <tr>
            {head.map((h, i) => (
              <th key={`${h}-${i}`} scope="col" className={align(i)}>
                {h}
              </th>
            ))}
          </tr>
        </thead>
        {groupBy ? (
          [...new Set(rows.map((r) => String(r[groupBy.col] ?? "")))]
            .sort((a, b) => a.localeCompare(b))
            .map((g) => {
              const idx = rows.map((_, i) => i).filter((i) => String(rows[i][groupBy.col] ?? "") === g);
              return (
                <tbody key={g}>
                  <tr>
                    <td colSpan={head.length} className="text-left font-bold" style={{ background: "var(--color-brand-soft)" }}>
                      {head[groupBy.col]}: {g || "—"}
                    </td>
                  </tr>
                  {idx.map((i) => (
                    <tr key={i}>
                      {rows[i].map((cell, j) => (
                        <td key={j} className={align(j)}>
                          {cell}
                        </td>
                      ))}
                    </tr>
                  ))}
                  {groupBy.subtotal && <TotalRow cells={groupBy.subtotal(idx)} textCols={textCols} />}
                </tbody>
              );
            })
        ) : (
          <tbody>
            {rows.map((r, i) => (
              <tr key={i}>
                {r.map((cell, j) => (
                  <td key={j} className={align(j)}>
                    {cell}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        )}
        {total && (
          <tfoot>
            <TotalRow cells={total} textCols={textCols} />
          </tfoot>
        )}
      </table>
    </div>
  );
}

/** The highlighted TOTAL row. Used by ReportTable; exported for tables built by hand. */
export function TotalRow({ cells, textCols = [0] }: { cells: ReactNode[]; textCols?: number[] }) {
  return (
    <tr className="rpt-total">
      {cells.map((cell, j) => (
        <td key={j} className={textCols.includes(j) ? "text-left" : "text-right"}>
          {cell}
        </td>
      ))}
    </tr>
  );
}
