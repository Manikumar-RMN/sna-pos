"use client";

import { useState } from "react";
import { money } from "@/lib/format";
import { undoSupplierPayment } from "./actions";
import { dayLabel, payMethodLabel, type PaymentRow } from "./helpers";
import { Badge, Field, Msg, lineStyle, rowBtn, useRun } from "./ui";

const struck: React.CSSProperties = { textDecoration: "line-through", color: "var(--color-ink-3)" };

/**
 * The payments recorded against one goods receipt, behind a "Payments" line that
 * opens. A payment typed wrongly can be undone here: it asks for a reason first.
 * Nothing is deleted — an undone payment stays in the list, marked "Undone".
 */
export function PaymentsList({
  payments,
  currency,
  disabled,
  locked,
  onDone,
}: {
  /** This receipt's payments, oldest first. */
  payments: PaymentRow[];
  currency: string;
  /** Something else on the screen is being saved. */
  disabled?: boolean;
  /** The supplier has refunded money on this receipt, so its payments stay as they are. */
  locked?: boolean;
  /** Called with the words to show once a payment has been undone. */
  onDone: (text: string) => void;
}) {
  const { pending, msg, setMsg, run } = useRun();
  const [undoId, setUndoId] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const m = (n: number) => money(n, currency);
  if (payments.length === 0) return null;

  return (
    <details className="mt-2">
      <summary className="cursor-pointer py-2 text-sm font-semibold" style={{ color: "var(--color-ink-2)" }}>
        Payments ({payments.length})
      </summary>
      <ul className="space-y-2">
        {payments.map((p) => (
          <li key={p.id} className="rounded-xl border p-3" style={lineStyle}>
            <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
              <div className="min-w-0 text-sm">
                <span style={p.undone ? struck : undefined}>
                  {dayLabel(p.paid_on)} · {payMethodLabel(p.method)}
                  {p.from_till ? " from the till" : ""}
                  {p.reference ? ` · ref ${p.reference}` : ""}
                </span>{" "}
                {p.undone && <Badge label="Undone" bg="var(--color-bad-soft)" fg="var(--color-bad)" />}
                {p.undone && p.undo_reason && (
                  <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                    Reason: {p.undo_reason}
                  </div>
                )}
              </div>
              <div className="flex items-center gap-3">
                <span className="font-bold tabular-nums" style={p.undone ? struck : undefined}>
                  {m(p.amount)}
                </span>
                {!p.undone && !locked && undoId !== p.id && (
                  <button
                    type="button"
                    className={rowBtn}
                    style={{ ...lineStyle, color: "var(--color-bad)" }}
                    onClick={() => {
                      setMsg(null);
                      setReason("");
                      setUndoId(p.id);
                    }}
                    disabled={disabled || pending}
                    aria-label={`Undo the payment of ${m(p.amount)} made on ${dayLabel(p.paid_on)}`}
                  >
                    Undo
                  </button>
                )}
              </div>
            </div>

            {undoId === p.id && !p.undone && (
              <div className="mt-3 rounded-2xl border p-3" style={{ borderColor: "var(--color-bad)", background: "var(--color-bad-soft)" }}>
                <div className="text-sm font-bold" style={{ color: "var(--color-bad)" }}>
                  Undo this payment of {m(p.amount)}? {p.from_till ? "The cash will be put back into the drawer that is open now." : "It will be owed to the supplier again."}
                </div>
                <Field label="Why is it being undone?" className="mt-2">
                  <input className="field h-10 text-sm" placeholder="e.g. wrong amount, entered twice" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} disabled={pending} />
                </Field>
                <div className="mt-2">
                  <Msg msg={msg && !msg.ok ? msg : null} />
                </div>
                <div className="mt-3 flex flex-wrap gap-2">
                  <button
                    type="button"
                    className="btn px-4 text-sm"
                    style={{ background: "var(--color-bad)", color: "#fff" }}
                    disabled={disabled || pending || reason.trim().length < 3}
                    onClick={() =>
                      run(
                        () => undoSupplierPayment(p.id, reason),
                        (r) => {
                          setUndoId(null);
                          setReason("");
                          const text = `Payment of ${m(r.amount)} undone. ${m(r.balance)} is now owed on ${r.number}.`;
                          onDone(text);
                          return text;
                        },
                        "Could not reach the server. Check whether this payment now shows as Undone before you try again.",
                      )
                    }
                  >
                    {pending ? "Undoing…" : "Yes, undo this payment"}
                  </button>
                  <button type="button" className="btn border px-4 text-sm" style={{ ...lineStyle, background: "var(--color-surface)" }} onClick={() => setUndoId(null)} disabled={pending}>
                    Keep it
                  </button>
                </div>
              </div>
            )}
          </li>
        ))}
      </ul>
    </details>
  );
}
