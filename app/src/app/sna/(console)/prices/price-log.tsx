import { indiaDateTime } from "../crm";

export type PriceLogRow = { at: string; item: string; currency: string; had_old: boolean; old: number | null; price: number | null; by: string | null };

const show = (v: number | null) => (v === null || v === undefined ? "not priced" : String(Number(v)));

/** The last price changes: what it was, what it became, who did it. Older entries did not keep the old price. */
export function PriceLog({ rows, names }: { rows: PriceLogRow[]; names: Record<string, string> }) {
  return (
    <section className="card mt-5 overflow-hidden">
      <h2 className="px-4 py-3 text-base font-bold" style={{ borderBottom: "1px solid var(--color-line)" }}>
        Recent price changes
      </h2>
      {rows.length === 0 ? (
        <p className="px-4 py-3 text-sm" style={{ color: "var(--color-ink-3)" }}>
          No price changes recorded yet.
        </p>
      ) : (
        <ul className="divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
          {rows.map((r, i) => (
            <li key={i} className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 px-4 py-2.5">
              <span>
                <span className="font-semibold">{names[r.item] ?? r.item}</span> in {r.currency}:{" "}
                {r.had_old ? (
                  <>
                    {show(r.old)} <span aria-hidden>→</span> <span className="font-semibold">{show(r.price)}</span>
                  </>
                ) : (
                  <>
                    set to <span className="font-semibold">{show(r.price)}</span> <span style={{ color: "var(--color-ink-3)" }}>(earlier price not recorded)</span>
                  </>
                )}
              </span>
              <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                {indiaDateTime(r.at)}
                {r.by ? ` · ${r.by}` : ""}
              </span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
