"use client";

import { useState } from "react";

const QUICK = ["Guest asked for another copy", "Printer jammed / bad print", "Wrong paper or size", "Kitchen did not get the ticket"];

/** Asked before a bill or kitchen ticket is printed again: the reason is saved in the audit log. */
export function ReprintReasonPrompt({ what, onCancel, onConfirm }: { what: string; onCancel: () => void; onConfirm: (reason: string) => void }) {
  const [reason, setReason] = useState("");
  const ok = reason.trim().length >= 3;
  return (
    <div className="no-print fixed inset-0 z-50 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="card w-full max-w-sm p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label="Reprint reason">
        <h3 className="text-lg font-bold">Why print {what} again?</h3>
        <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
          This is a copy, not the first print. The reason is saved in the audit log.
        </p>
        <div className="mt-3 flex flex-wrap gap-1.5">
          {QUICK.map((q) => (
            <button key={q} type="button" className="rounded-lg border px-2 py-1 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setReason(q)}>
              {q}
            </button>
          ))}
        </div>
        <input
          autoFocus
          className="field mt-3 w-full"
          placeholder="Reason (required)"
          value={reason}
          maxLength={200}
          onChange={(e) => setReason(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && ok && onConfirm(reason.trim())}
        />
        <div className="mt-4 flex gap-2">
          <button className="btn border flex-1" style={{ borderColor: "var(--color-line)" }} onClick={onCancel}>
            Cancel
          </button>
          <button className="btn btn-primary flex-1" disabled={!ok} onClick={() => onConfirm(reason.trim())}>
            Print
          </button>
        </div>
      </div>
    </div>
  );
}

export const needsReason = (error: string | null | undefined) => !!error && error.includes("(reprint.reason)");
