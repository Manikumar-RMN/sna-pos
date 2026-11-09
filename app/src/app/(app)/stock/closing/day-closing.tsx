"use client";

import { useState } from "react";
import { Field, Msg, useRun } from "../../purchases/ui";
import { closeDay, reopenDay } from "./actions";

export type DayRow = { id: string; day: string; closedAt: string; revoked: boolean; reason: string | null };

export function DayClosing({ canManage, isOwner, yesterday, days }: { canManage: boolean; isOwner: boolean; yesterday: string; days: DayRow[] }) {
  const { pending, msg, run } = useRun();
  const [day, setDay] = useState(yesterday);
  const [reopenId, setReopenId] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const open = days.filter((d) => !d.revoked);
  return (
    <section className="card mt-6 p-4">
      <h2 className="text-sm font-bold">Day closing</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Close a finished day to lock it: no receipt, issue or count can be saved on that date. Only the owner can re-open it.
      </p>
      <Msg msg={msg} />
      {canManage && (
        <div className="mt-3 flex flex-wrap items-end gap-2">
          <Field label="Day to close">
            <input type="date" className="field h-10 text-sm" value={day} max={yesterday} onChange={(e) => setDay(e.target.value)} disabled={pending} />
          </Field>
          <button type="button" className="btn btn-primary px-4 text-sm" disabled={pending || !day} onClick={() => run(() => closeDay(day))}>
            {pending ? "Closing…" : "Close day"}
          </button>
        </div>
      )}
      <ul className="mt-3 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
        {open.length === 0 && <li className="py-2 text-xs" style={{ color: "var(--color-ink-3)" }}>No closed days.</li>}
        {open.map((d) => (
          <li key={d.id} className="py-2">
            <div className="flex items-center justify-between gap-2">
              <span>
                <b>{new Date(d.day + "T00:00:00").toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" })}</b> <span className="badge">Closed</span>
              </span>
              {isOwner && (
                <button type="button" className="text-xs font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => setReopenId(reopenId === d.id ? null : d.id)}>
                  Re-open
                </button>
              )}
            </div>
            {reopenId === d.id && (
              <div className="mt-2 flex flex-wrap items-end gap-2">
                <Field label="Reason">
                  <input className="field h-10 text-sm" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} disabled={pending} />
                </Field>
                <button type="button" className="btn px-4 text-sm" disabled={pending} onClick={() => run(() => reopenDay(d.id, reason), () => { setReopenId(null); setReason(""); return "Day re-opened."; })}>
                  Re-open day
                </button>
              </div>
            )}
          </li>
        ))}
      </ul>
    </section>
  );
}
