"use client";

import { useRouter } from "next/navigation";
import { useMemo, useRef, useState, useTransition } from "react";
import { money } from "@/lib/format";
import { buildCountLines, countDiff, countSummary, fmtQty, invalidCountRows, type CountRow } from "@/lib/stock";
import { useOnline } from "@/lib/use-online";
import { applyStockCount } from "./actions";

type SheetRow = Omit<CountRow, "counted"> & { category: string };

/** Count sheet: every ingredient with what the system expects and a box for what was counted. One save. */
export function CountSheet({ currency, rows, openedAt }: { currency: string; rows: SheetRow[]; openedAt?: string }) {
  const router = useRouter();
  const online = useOnline();
  const [pending, start] = useTransition();
  const [counted, setCounted] = useState<Record<string, string>>({});
  const [q, setQ] = useState("");
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const clientRef = useRef<string>(crypto.randomUUID());
  const m = (x: number) => money(x, currency);

  const all: (CountRow & { category: string })[] = useMemo(() => rows.map((r) => ({ ...r, counted: counted[r.id] ?? "" })), [rows, counted]);
  const summary = countSummary(all);
  const bad = invalidCountRows(all);
  const needle = q.trim().toLowerCase();
  const shown = all.filter((r) => !needle || r.name.toLowerCase().includes(needle) || (rows.find((x) => x.id === r.id)?.category ?? "").toLowerCase().includes(needle));

  function save() {
    if (bad.length > 0) {
      setMsg({ ok: false, text: "Some counted quantities are not numbers. Fix the red boxes." });
      return;
    }
    const lines = buildCountLines(all);
    if (lines.length === 0) {
      setMsg({ ok: false, text: "Enter at least one counted quantity." });
      return;
    }
    setMsg(null);
    start(async () => {
      const r = await applyStockCount({ lines, note, clientRef: clientRef.current, openedAt });
      setMsg(r.ok ? { ok: true, text: r.message ?? "Count saved." } : { ok: false, text: r.error });
      if (r.ok) {
        clientRef.current = crypto.randomUUID();
        setCounted({});
        setNote("");
        router.refresh();
      }
    });
  }

  return (
    <div className="space-y-4">
      <input className="field h-10 text-sm" placeholder="Search ingredient or group" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search" />

      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr style={{ color: "var(--color-ink-3)" }}>
              <th className="px-3 py-2 text-left text-xs font-semibold">Ingredient</th>
              <th className="px-3 py-2 text-right text-xs font-semibold">Expected</th>
              <th className="px-3 py-2 text-right text-xs font-semibold">Counted</th>
              <th className="px-3 py-2 text-right text-xs font-semibold">Difference</th>
              <th className="px-3 py-2 text-right text-xs font-semibold">Value</th>
            </tr>
          </thead>
          <tbody>
            {shown.length === 0 && (
              <tr>
                <td colSpan={5} className="px-3 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                  {rows.length === 0 ? "No ingredients yet. Add them on the Stock page." : "Nothing matches the search."}
                </td>
              </tr>
            )}
            {shown.map((r) => {
              const d = countDiff(r);
              const invalid = bad.includes(r.id);
              const tone = !d || d.diff === 0 ? undefined : d.diff < 0 ? "var(--color-bad)" : "var(--color-ok)";
              return (
                <tr key={r.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                  <td className="px-3 py-2">
                    <div className="font-semibold">{r.name}</div>
                    {r.category && (
                      <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                        {r.category}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums" style={{ color: r.expected < 0 ? "var(--color-bad)" : undefined }}>
                    {fmtQty(r.expected)} {r.unit}
                  </td>
                  <td className="px-3 py-2 text-right">
                    <input
                      className="field h-10 w-24 text-right text-sm"
                      style={{ width: 96, borderColor: invalid ? "var(--color-bad)" : undefined }}
                      inputMode="decimal"
                      placeholder={r.unit}
                      value={r.counted}
                      onChange={(e) => setCounted({ ...counted, [r.id]: e.target.value })}
                      aria-label={`Counted ${r.name}`}
                      aria-invalid={invalid}
                    />
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums" style={{ color: tone, fontWeight: tone ? 700 : 400 }}>
                    {d ? `${d.diff > 0 ? "+" : ""}${fmtQty(d.diff)} ${r.unit}` : "—"}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums" style={{ color: tone }}>
                    {d ? m(d.value) : "—"}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <section className="card p-4">
        <input className="field h-10 text-sm" placeholder="Note (optional), e.g. Monday night count" value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} aria-label="Note" />
        <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
          <div className="text-sm">
            {summary.counted} counted · {summary.changed} to correct · difference{" "}
            <b className="tabular-nums" style={{ color: summary.variance < 0 ? "var(--color-bad)" : undefined }}>
              {m(summary.variance)}
            </b>
          </div>
          <button className="btn btn-primary px-5 text-sm" disabled={pending || !online || summary.counted === 0} onClick={save}>
            {pending ? "Saving…" : "Save count"}
          </button>
        </div>
        <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
          Expected stock is read again when you save, so sales made while you counted are taken into account.
        </p>
        {!online && (
          <p className="mt-2 text-xs font-semibold" style={{ color: "var(--color-warn)" }}>
            Needs internet.
          </p>
        )}
        {msg && (
          <p className="mt-2 text-sm font-semibold" role={msg.ok ? "status" : "alert"} style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
            {msg.text}
          </p>
        )}
      </section>
    </div>
  );
}
