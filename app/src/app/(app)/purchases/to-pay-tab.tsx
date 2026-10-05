"use client";

import { useState } from "react";
import { money } from "@/lib/format";
import { dayLabel, type OwedRow, type PaymentRow } from "./helpers";
import { PayForm } from "./pay-form";
import { PaymentsList } from "./payments-list";
import { Badge, Msg, rowBtn, type Note } from "./ui";

/** Everything still owed to suppliers, earliest due date first, each with a Pay button. */
export function OwedList({
  owed,
  payments,
  currency,
  country,
  today,
  canTill,
}: {
  owed: OwedRow[];
  /** The payments made on those receipts, by receipt id, oldest first. */
  payments: Record<string, PaymentRow[]>;
  currency: string;
  country: string;
  today: string;
  canTill: boolean;
}) {
  const [payId, setPayId] = useState<string | null>(null);
  const [msg, setMsg] = useState<Note>(null);
  const m = (n: number) => money(n, currency);

  return (
    <section>
      <h2 className="mb-2 text-sm font-bold">Still to pay</h2>
      <Msg msg={msg} />
      <div className="card mt-2">
        {owed.length === 0 ? (
          <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
            Nothing is owed to suppliers.
          </p>
        ) : (
          <ul>
            {owed.map((r, i) => (
              <li key={r.id} className="px-4 py-3" style={i > 0 ? { borderTop: "1px solid var(--color-line)" } : undefined}>
                <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
                  <div className="min-w-0">
                    <span className="font-semibold">{r.supplier}</span> {r.overdue && <Badge label="Overdue" bg="var(--color-bad-soft)" fg="var(--color-bad)" />}
                    <div className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                      {r.number}
                      {r.bill_no ? ` · bill ${r.bill_no}` : ""} · received {dayLabel(r.received_on)}
                    </div>
                    <div className="text-sm" style={{ color: r.overdue ? "var(--color-bad)" : "var(--color-ink-2)", fontWeight: r.overdue ? 700 : 400 }}>
                      {r.due_on ? `Due ${dayLabel(r.due_on)}` : "No due date"}
                      {r.paid > 0 ? ` · ${m(r.paid)} of ${m(r.total)} paid` : ""}
                    </div>
                  </div>
                  <div className="flex items-center gap-3">
                    <div className="text-base font-bold tabular-nums">{m(r.owed)}</div>
                    {payId !== r.id && (
                      <button
                        type="button"
                        className={rowBtn}
                        style={{ borderColor: "var(--color-brand)", background: "var(--color-brand)", color: "#fff" }}
                        onClick={() => {
                          setMsg(null);
                          setPayId(r.id);
                        }}
                        aria-label={`Pay ${r.supplier}, ${r.number}`}
                      >
                        Pay
                      </button>
                    )}
                  </div>
                </div>
                {payId === r.id && (
                  <PayForm
                    receipt={{ id: r.id, number: r.number, supplier: r.supplier, owed: r.owed }}
                    currency={currency}
                    country={country}
                    today={today}
                    canTill={canTill}
                    onDone={(text) => {
                      setPayId(null);
                      setMsg({ ok: true, text });
                    }}
                    onClose={() => setPayId(null)}
                  />
                )}
                <PaymentsList payments={payments[r.id] ?? []} currency={currency} onDone={(text) => setMsg({ ok: true, text })} />
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}
