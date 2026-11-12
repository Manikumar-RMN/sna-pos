"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { saveDaySettings, saveSessions } from "../actions";

export type SessionRow = { name: string; start: string; end: string; days: number[] };
const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

function Msg({ m }: { m: { ok: boolean; text: string } | null }) {
  if (!m) return null;
  return (
    <p role={m.ok ? "status" : "alert"} className="text-sm font-semibold" style={{ color: m.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
      {m.text}
    </p>
  );
}

export function DaySettingsForm({ shiftsEnabled, cutoff, nightAudit }: { shiftsEnabled: boolean; cutoff: string; nightAudit: "auto" | "manual" }) {
  const router = useRouter();
  const [on, setOn] = useState(shiftsEnabled);
  const [cut, setCut] = useState(cutoff);
  const [audit, setAudit] = useState<"auto" | "manual">(nightAudit);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  return (
    <section className="card space-y-4 p-4">
      <h2 className="text-base font-bold">Business day</h2>
      <label className="flex items-start gap-3">
        <input type="checkbox" className="mt-1 h-5 w-5" checked={on} onChange={(e) => setOn(e.target.checked)} />
        <span>
          <span className="block text-sm font-semibold">Use shifts (each cashier opens and counts a cash drawer)</span>
          <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
            Off (recommended for small cafés): billing starts straight away and the cash is counted once, when the day is closed. On: a
            shift must be opened with the opening cash before billing, and closed with a count. The change applies from the next shift.
          </span>
        </span>
      </label>
      <label className="block text-sm">
        <span className="mb-1 block font-semibold">The business day ends at</span>
        <input type="time" className="field w-40" value={cut} min="00:00" max="08:00" onChange={(e) => setCut(e.target.value)} />
        <span className="mt-1 block text-xs" style={{ color: "var(--color-ink-3)" }}>
          Bills made after midnight but before this time count for the previous day (e.g. a 12:30 a.m. dinner bill). Between midnight and 8 a.m.
        </span>
      </label>
      <fieldset className="space-y-2 text-sm">
        <legend className="mb-1 font-semibold">Night audit (closing the day)</legend>
        <label className="flex items-start gap-3">
          <input type="radio" name="nightaudit" className="mt-1 h-5 w-5" checked={audit === "auto"} onChange={() => setAudit("auto")} />
          <span>
            <span className="block font-semibold">Automatic</span>
            <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
              The day closes by itself when the next business day starts, if every bill is paid or voided. If a bill is still open, the day stays open until it is settled.
            </span>
          </span>
        </label>
        <label className="flex items-start gap-3">
          <input type="radio" name="nightaudit" className="mt-1 h-5 w-5" checked={audit === "manual"} onChange={() => setAudit("manual")} />
          <span>
            <span className="block font-semibold">Manual</span>
            <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
              The day never closes by itself. Someone runs Day close (the &quot;Day not closed - tap to close&quot; box at the top) after the last bill, and bills keep going on that day until then.
            </span>
          </span>
        </label>
      </fieldset>
      <button
        className="btn btn-primary"
        disabled={pending}
        onClick={() =>
          start(async () => {
            const r = await saveDaySettings(on, cut, audit);
            setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
            if (r.ok) router.refresh();
          })
        }
      >
        Save
      </button>
      <Msg m={msg} />
    </section>
  );
}

export function SessionsForm({ initial, outlet }: { initial: SessionRow[]; outlet: { id: string; name: string; ownTimes: boolean } | null }) {
  const router = useRouter();
  const [rows, setRows] = useState<SessionRow[]>(initial);
  const [forOutlet, setForOutlet] = useState(!!outlet?.ownTimes);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const set = (i: number, patch: Partial<SessionRow>) => setRows(rows.map((r, k) => (k === i ? { ...r, ...patch } : r)));

  return (
    <section className="card space-y-3 p-4">
      <div>
        <h2 className="text-base font-bold">Meal sessions</h2>
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          Every bill is tagged with the session in which the order was opened, so a table seated at 2:50 and paid at 3:20 counts as lunch. Sessions
          cannot overlap; time outside every session is reported as &quot;Other&quot;. A session may run past midnight (e.g. Dinner 19:00–01:00).
          Changing times never changes old bills.
        </p>
      </div>
      {outlet && (
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={forOutlet} onChange={(e) => setForOutlet(e.target.checked)} />
          Different times for {outlet.name} only (otherwise these times apply to all outlets)
        </label>
      )}
      <div className="space-y-2">
        {rows.map((r, i) => (
          <div key={i} className="rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
            <div className="flex flex-wrap items-center gap-2">
              <input className="field min-w-0 flex-1" style={{ minWidth: 140 }} value={r.name} maxLength={30} onChange={(e) => set(i, { name: e.target.value })} aria-label="Session name" />
              <input type="time" className="field w-32" value={r.start} onChange={(e) => set(i, { start: e.target.value })} aria-label="Starts" />
              <span className="text-sm">to</span>
              <input type="time" className="field w-32" value={r.end} onChange={(e) => set(i, { end: e.target.value })} aria-label="Ends" />
              <button className="text-sm font-semibold" style={{ color: "var(--color-bad)" }} onClick={() => setRows(rows.filter((_, k) => k !== i))}>
                Remove
              </button>
            </div>
            <div className="mt-2 flex flex-wrap gap-1.5">
              {DAYS.map((d, k) => {
                const on = r.days.includes(k + 1);
                return (
                  <button
                    key={d}
                    type="button"
                    aria-pressed={on}
                    onClick={() => set(i, { days: on ? r.days.filter((x) => x !== k + 1) : [...r.days, k + 1].sort() })}
                    className="rounded-lg border px-2 py-1 text-xs font-semibold"
                    style={on ? { background: "var(--color-brand-soft)", borderColor: "var(--color-brand)" } : { borderColor: "var(--color-line)", color: "var(--color-ink-3)" }}
                  >
                    {d}
                  </button>
                );
              })}
            </div>
          </div>
        ))}
      </div>
      <div className="flex flex-wrap gap-2">
        <button
          className="btn border"
          style={{ borderColor: "var(--color-line)" }}
          disabled={rows.length >= 12}
          onClick={() => setRows([...rows, { name: "", start: "00:00", end: "00:00", days: [1, 2, 3, 4, 5, 6, 7] }])}
        >
          + Add session
        </button>
        <button
          className="btn btn-primary"
          disabled={pending}
          onClick={() =>
            start(async () => {
              const r = await saveSessions(outlet && forOutlet ? outlet.id : null, rows, outlet && !forOutlet && outlet.ownTimes ? outlet.id : null);
              setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
              if (r.ok) router.refresh();
            })
          }
        >
          Save sessions
        </button>
      </div>
      <Msg m={msg} />
    </section>
  );
}
