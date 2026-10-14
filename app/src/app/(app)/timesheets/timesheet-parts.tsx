"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { clockIn, clockOut, fixEntry } from "./actions";
import { fromZonedInput, toZonedInput } from "@/lib/format";

const show = (iso: string | null, tz: string) =>
  iso ? new Date(iso).toLocaleString("en-IN", { timeZone: tz, day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }) : "—";

export function ClockButton({ clockedInAt, timezone, name }: { clockedInAt: string | null; timezone: string; name: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <section className="card flex flex-wrap items-center justify-between gap-3 p-4">
      <div className="text-sm">
        <b>{name}</b> — {clockedInAt ? `clocked in since ${show(clockedInAt, timezone)}` : "not clocked in"}
      </div>
      <button
        className={`btn ${clockedInAt ? "border" : "btn-pay"}`}
        style={clockedInAt ? { borderColor: "var(--color-line)" } : undefined}
        disabled={pending}
        onClick={() =>
          start(async () => {
            const r = clockedInAt ? await clockOut() : await clockIn();
            if (!r.ok) setError(r.error);
            else router.refresh();
          })
        }
      >
        {clockedInAt ? "Clock out" : "Clock in"}
      </button>
      {error && <p role="alert" className="w-full text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{error}</p>}
    </section>
  );
}

export function EntryRow({
  entry,
  canFix,
  timezone,
}: {
  entry: { id: string; person: string; clockIn: string; clockOut: string | null; reason: string | null; hours: number };
  canFix: boolean;
  timezone: string;
}) {
  const router = useRouter();
  const [editing, setEditing] = useState(false);
  const [inAt, setIn] = useState(toZonedInput(entry.clockIn, timezone));
  const [outAt, setOut] = useState(toZonedInput(entry.clockOut, timezone));
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <>
      <tr className="border-t" style={{ borderColor: "var(--color-line)" }}>
        <td className="py-1.5">{entry.person}</td>
        <td>{show(entry.clockIn, timezone)}</td>
        <td>{entry.clockOut ? show(entry.clockOut, timezone) : <b>still in</b>}</td>
        <td className="text-right tabular-nums">{entry.clockOut ? entry.hours.toFixed(2) : "—"}</td>
        <td className="text-right">
          {canFix && (
            <button className="text-xs font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => setEditing(!editing)}>
              Fix
            </button>
          )}
        </td>
      </tr>
      {entry.reason && (
        <tr><td colSpan={5} className="pb-1 text-xs" style={{ color: "var(--color-ink-3)" }}>Changed: {entry.reason}</td></tr>
      )}
      {editing && (
        <tr>
          <td colSpan={5} className="pb-3">
            <div className="flex flex-wrap items-end gap-2">
              <input className="field w-auto" type="datetime-local" value={inAt} onChange={(e) => setIn(e.target.value)} aria-label="Clock in" />
              <input className="field w-auto" type="datetime-local" value={outAt} onChange={(e) => setOut(e.target.value)} aria-label="Clock out" />
              <input className="field min-w-0 flex-1" placeholder="Reason (required)" value={reason} onChange={(e) => setReason(e.target.value)} />
              <button
                className="btn btn-primary"
                disabled={pending}
                onClick={() =>
                  start(async () => {
                    const r = await fixEntry(entry.id, fromZonedInput(inAt, timezone), outAt ? fromZonedInput(outAt, timezone) : null, reason);
                    if (!r.ok) return setError(r.error);
                    setEditing(false);
                    router.refresh();
                  })
                }
              >
                Save
              </button>
            </div>
            {error && <p role="alert" className="mt-1 text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{error}</p>}
          </td>
        </tr>
      )}
    </>
  );
}
