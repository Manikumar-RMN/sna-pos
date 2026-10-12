"use client";

import { useState, useTransition } from "react";
import { approveWithPin } from "./approval-actions";

const LABELS: Record<string, string> = {
  "order.discount": "give this discount or free bill",
  "order.void": "void or cancel",
  "order.refund": "issue a credit note",
  "payment.take": "take this payment",
  "payment.change_mode": "change the payment mode",
  "day.close": "close the day",
  "day.reopen": "reopen the day",
  "cash.movement": "record cash in / out",
  "shift.close": "close the shift",
};

/** Finds "(order.discount)"-style right names that the database puts in "not allowed" messages. */
export function neededRight(message: string | null | undefined): string | null {
  const m = message?.match(/\(([a-z]+\.[a-z_]+)\)/);
  return m ? m[1] : null;
}

/** The message without the technical right name. */
export function cleanMessage(message: string) {
  return message.replace(/\s*\([a-z]+\.[a-z_]+\)/, "");
}

/** Manager PIN pop-up. After approval, `onApproved` retries the action once. */
export function ApprovalPrompt({ permission, onApproved, onCancel }: { permission: string; onApproved: (approver: string) => void; onCancel: () => void }) {
  const [pin, setPin] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function press(d: string) {
    setError(null);
    setPin((p) => (p.length < 6 ? p + d : p));
  }
  function submit() {
    start(async () => {
      const res = await approveWithPin(pin, permission);
      if (!res.ok) {
        setError(res.error);
        setPin("");
        return;
      }
      onApproved(res.approver);
    });
  }

  return (
    <div className="no-print fixed inset-0 z-50 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="card w-full max-w-xs p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label="Manager approval">
        <h3 className="text-lg font-bold">Manager approval</h3>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
          A manager enters their PIN to {LABELS[permission] ?? "allow this"}. It allows this one action.
        </p>
        <div className="my-4 flex justify-center gap-2" aria-live="polite" aria-label={`${pin.length} digits entered`}>
          {[0, 1, 2, 3, 4, 5].map((i) => (
            <span key={i} className="h-3.5 w-3.5 rounded-full" style={{ background: i < pin.length ? "var(--color-brand)" : "var(--color-line)" }} />
          ))}
        </div>
        <div className="grid grid-cols-3 gap-2">
          {["1", "2", "3", "4", "5", "6", "7", "8", "9"].map((d) => (
            <button key={d} className="btn border text-lg" style={{ borderColor: "var(--color-line)" }} onClick={() => press(d)} disabled={pending}>
              {d}
            </button>
          ))}
          <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setPin((p) => p.slice(0, -1))} disabled={pending} aria-label="Delete last digit">
            ⌫
          </button>
          <button className="btn border text-lg" style={{ borderColor: "var(--color-line)" }} onClick={() => press("0")} disabled={pending}>
            0
          </button>
          <button className="btn btn-primary text-sm" onClick={submit} disabled={pending || pin.length < 4}>
            {pending ? "…" : "OK"}
          </button>
        </div>
        {error && (
          <p className="mt-3 rounded-lg px-3 py-2 text-xs" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
            {error}
          </p>
        )}
        <button className="mt-3 w-full text-center text-sm font-semibold" style={{ color: "var(--color-ink-3)" }} onClick={onCancel}>
          Cancel
        </button>
      </div>
    </div>
  );
}
