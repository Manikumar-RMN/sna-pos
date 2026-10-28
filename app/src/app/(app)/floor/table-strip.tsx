"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import {
  STATE_HELP,
  STATE_LABEL,
  STATE_ORDER,
  STATE_STYLE,
  OPEN_DELAYED_MIN,
  classifyTable,
  countStates,
  type FloorRow,
  type TableState,
} from "@/lib/table-status";
import { useFloorClock } from "./use-floor-clock";

export type StripBill = { id: string; billNumber: string; total: number };
export type StripTable = { id: string; number: string; seats: number | null; openBills: StripBill[] };

/**
 * All tables of the outlet as coloured tiles: free, busy, open too long, kitchen waiting, reserved.
 * Tap a table to select it (onSelect); a table with several open bills shows them as chips when it is selected.
 * The colours come from lib/table-status.ts; the facts come from `floor` (floor/load-floor.ts). With no floor rows the tiles fall back to
 * plain free / busy from `tables[].openBills`.
 */
export function TableStrip({
  tables,
  floor,
  currency,
  selectedTableId = null,
  selectedBillId = null,
  onSelect,
  counter,
  refreshMs = 20_000,
  compact = false,
}: {
  tables: StripTable[];
  floor: FloorRow[];
  currency: string;
  selectedTableId?: string | null;
  selectedBillId?: string | null;
  /** billId null = the table (a new bill, or the choice among several bills, is made by the caller). */
  onSelect: (tableId: string, billId: string | null) => void;
  /** Optional "Counter / takeaway" tile in front of the tables. */
  counter?: { selected: boolean; onSelect: () => void; label?: string };
  /** Ask the server for fresh data this often (0 = never; the caller refreshes). */
  refreshMs?: number;
  compact?: boolean;
}) {
  const router = useRouter();
  const elapsed = useFloorClock(floor);
  useEffect(() => {
    if (!refreshMs) return;
    const t = setInterval(() => router.refresh(), refreshMs);
    return () => clearInterval(t);
  }, [refreshMs, router]);

  const byId = new Map(floor.map((r) => [r.table_id, r]));
  const m = (n: number) => money(n, currency);
  const counts = floor.length ? countStates(floor, elapsed) : null;
  const selected = tables.find((t) => t.id === selectedTableId) ?? null;

  return (
    <div className="no-print">
      <div className={`grid gap-2 ${compact ? "grid-cols-4 sm:grid-cols-6 lg:grid-cols-8" : "grid-cols-3 sm:grid-cols-5 lg:grid-cols-8"}`} role="list" aria-label="Tables">
        {counter && (
          <button
            type="button"
            role="listitem"
            aria-pressed={counter.selected}
            onClick={counter.onSelect}
            className="tap card flex min-h-16 flex-col items-start justify-between p-2 text-left"
            style={{
              borderColor: "var(--color-line)",
              boxShadow: counter.selected ? SELECTED_RING : undefined,
            }}
          >
            <span className="flex w-full items-start justify-between gap-1">
              <span className="text-sm font-bold">{counter.label ?? "Counter"}</span>
              {counter.selected && <SelectedMark />}
            </span>
            <span className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
              Takeaway
            </span>
          </button>
        )}
        {tables.map((t) => {
          const row = byId.get(t.id);
          const fallbackBusy = t.openBills.length > 0;
          const st = row ? classifyTable(row, elapsed) : null;
          const state: TableState = st ? st.state : fallbackBusy ? "busy" : "free";
          const style = STATE_STYLE[state];
          const isSel = t.id === selectedTableId;
          const total = row ? row.open_total : t.openBills.reduce((s, b) => s + b.total, 0);
          const bills = row ? row.open_bills : t.openBills.length;
          const note = st?.note ?? "";
          const label = `Table ${t.number}, ${STATE_LABEL[state]}${note ? `, ${note}` : ""}${bills ? `, ${bills} open bill${bills === 1 ? "" : "s"}` : ""}`;
          return (
            <button
              key={t.id}
              type="button"
              role="listitem"
              aria-pressed={isSel}
              aria-label={label}
              onClick={() => onSelect(t.id, t.openBills.length === 1 ? t.openBills[0].id : null)}
              className="tap card relative flex min-h-16 flex-col items-start justify-between p-2 text-left"
              style={{
                ...style,
                borderWidth: 2,
                // Selected is independent of status: the status fill and border stay, a thick ink ring goes round the tile.
                boxShadow: isSel ? SELECTED_RING : undefined,
              }}
            >
              <span className="flex w-full items-start justify-between gap-1">
                <span className="text-base font-bold leading-none">{t.number}</span>
                {isSel && <SelectedMark />}
                {st?.reservedSoon && (
                  <span className="rounded px-1 text-[10px] font-bold" style={{ background: "var(--color-accent)", color: "var(--color-accent-ink)" }} title={`Booked: ${st.reservationName ?? ""}`}>
                    Booked
                  </span>
                )}
              </span>
              <span className="text-[11px] leading-tight" style={{ color: style.color ?? "var(--color-ink-2)" }}>
                {state === "free" ? (
                  <>Free{t.seats ? ` · ${t.seats} seats` : ""}</>
                ) : state === "reserved" ? (
                  <>
                    {st?.reservationName ?? "Booked"}
                    {st?.reservationParty ? ` · ${st.reservationParty}` : ""}
                    <br />
                    {note}
                  </>
                ) : (
                  <>
                    {m(total)}
                    <br />
                    {note}
                    {st && st.kotWaiting > 0 && state !== "kot_delayed" ? ` · ${st.kotWaiting} KOT` : ""}
                    {bills > 1 ? ` · ${bills} bills` : ""}
                  </>
                )}
              </span>
              {state !== "free" && state !== "reserved" && st && (
                <span aria-hidden className="mt-1 block h-1 w-full rounded-full" style={{ background: "rgba(255,255,255,.35)" }}>
                  <span
                    className="block h-1 rounded-full"
                    style={{ background: "#FFFFFF", width: `${state === "billed" ? 100 : Math.min(100, Math.round((st.openMinutes / OPEN_DELAYED_MIN) * 100))}%` }}
                  />
                </span>
              )}
            </button>
          );
        })}
      </div>

      {selected && selected.openBills.length > 1 && (
        <div className="mt-2 flex flex-wrap items-center gap-1.5" role="group" aria-label={`Open bills on table ${selected.number}`}>
          <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            T{selected.number} bills:
          </span>
          {selected.openBills.map((b) => (
            <button
              key={b.id}
              type="button"
              aria-pressed={b.id === selectedBillId}
              onClick={() => onSelect(selected.id, b.id)}
              className="rounded-md border px-2.5 py-1 text-xs font-semibold"
              style={{
                borderColor: b.id === selectedBillId ? "var(--color-brand)" : "var(--color-line)",
                background: b.id === selectedBillId ? "var(--color-brand)" : "transparent",
                color: b.id === selectedBillId ? "#fff" : "var(--color-ink-2)",
              }}
            >
              {b.billNumber} · {m(b.total)}
            </button>
          ))}
          <button
            type="button"
            onClick={() => onSelect(selected.id, null)}
            className="rounded-md border border-dashed px-2.5 py-1 text-xs font-semibold"
            style={{ borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
          >
            + New bill
          </button>
        </div>
      )}

      <TableLegend counts={counts} />
    </div>
  );
}

/** The selected tile: a thick ink ring outside the tile (white gap, then ink), whatever the status colour is. */
const SELECTED_RING = "0 0 0 2px var(--color-surface, #fff), 0 0 0 5px var(--color-ink)";

/** Small "Selected" marker with a check, so selection does not rely on the ring alone. */
function SelectedMark() {
  return (
    <span className="rounded px-1 text-[10px] font-bold leading-4" style={{ background: "#fff", color: "var(--color-ink)" }}>
      <span aria-hidden>✓ </span>Selected
    </span>
  );
}

/** What the colours mean (text as well as colour, so it does not depend on seeing the colours). */
export function TableLegend({ counts }: { counts?: Record<TableState, number> | null }) {
  return (
    <ul className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-[11px]" style={{ color: "var(--color-ink-3)" }} aria-label="Table colours">
      {STATE_ORDER.map((s) => (
        <li key={s} className="flex items-center gap-1" title={STATE_HELP[s]}>
          <span
            aria-hidden
            className="inline-block h-3 w-3 rounded-sm"
            style={{ borderWidth: 2, borderStyle: STATE_STYLE[s].borderStyle ?? "solid", borderColor: STATE_STYLE[s].borderColor, background: STATE_STYLE[s].background }}
          />
          {STATE_LABEL[s]}
          {counts ? ` ${counts[s]}` : ""}
        </li>
      ))}
    </ul>
  );
}
