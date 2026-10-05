"use client";

import { useRef, useState } from "react";
import { money } from "@/lib/format";
import { paySupplier } from "./actions";
import { amountCents, payMethods, refFor, type PayMethod, type PayTarget, type SentRef } from "./helpers";
import { Field, Msg, lineStyle, useRun } from "./ui";

/** Record a payment to a supplier against one goods receipt. Opens under the row it belongs to. */
export function PayForm({
  receipt,
  currency,
  country,
  today,
  canTill,
  onDone,
  onClose,
}: {
  receipt: PayTarget;
  currency: string;
  country: string;
  today: string;
  /** This person may take cash out of the till (the "cash in / cash out" right). */
  canTill: boolean;
  /** Called with the words to show once the payment is saved. */
  onDone: (text: string) => void;
  onClose: () => void;
}) {
  const { pending, msg, setMsg, run } = useRun();
  const methods = payMethods(country);
  const [amount, setAmount] = useState(receipt.owed.toFixed(2));
  const [method, setMethod] = useState<PayMethod>("cash");
  const [reference, setReference] = useState("");
  const [paidOn, setPaidOn] = useState(today);
  const [fromTill, setFromTill] = useState(false);
  // The reference goes with what was sent: the same payment tried again keeps it, a changed one gets a new one.
  const sent = useRef<SentRef | null>(null);
  const m = (n: number) => money(n, currency);

  function save() {
    const cents = amountCents(amount);
    if (cents === null || cents <= 0) return setMsg({ ok: false, text: "Enter the amount paid." });
    if (cents > Math.round(receipt.owed * 100)) return setMsg({ ok: false, text: `Only ${m(receipt.owed)} is still owed on ${receipt.number}.` });
    if (!paidOn) return setMsg({ ok: false, text: "Choose the date it was paid." });
    const payload = { receiptId: receipt.id, amount: cents / 100, method, reference, paidOn, fromTill: method === "cash" && fromTill };
    const mine = refFor(sent.current, payload);
    sent.current = mine;
    run(
      () => paySupplier({ ...payload, clientRef: mine.ref }),
      (r) => {
        // This reference is used up: anything saved after this is another payment.
        sent.current = null;
        const text = r.balance > 0 ? `Paid ${m(r.amount)} to ${receipt.supplier}. ${m(r.balance)} is still owed on ${receipt.number}.` : `Paid ${m(r.amount)} to ${receipt.supplier}. ${receipt.number} is now fully paid.`;
        onDone(text);
        return text;
      },
      "Could not reach the server. Check the connection and tap Save payment again without changing anything — it will not be paid twice.",
    );
  }

  return (
    <div className="mt-3 rounded-2xl border p-3" style={{ ...lineStyle, background: "var(--color-surface-2)" }}>
      <div className="text-sm font-bold">
        Pay {receipt.supplier} — {receipt.number} ({m(receipt.owed)} owed)
      </div>
      <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Field label="Amount paid">
          <input className="field h-10 text-sm" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={pending} />
        </Field>
        <Field label="Paid by">
          <select className="field h-10 text-sm" value={method} onChange={(e) => setMethod(e.target.value as PayMethod)} disabled={pending}>
            {methods.map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Reference" hint="(optional)">
          <input className="field h-10 text-sm" placeholder="Cheque or transfer number" value={reference} onChange={(e) => setReference(e.target.value)} maxLength={60} disabled={pending} />
        </Field>
        <Field label="Date paid">
          <input className="field h-10 text-sm" type="date" max={today} value={paidOn} onChange={(e) => setPaidOn(e.target.value)} disabled={pending} />
        </Field>
      </div>
      {method === "cash" && canTill && (
        <label className="mt-3 flex min-h-10 items-center gap-2 text-sm">
          <input type="checkbox" className="h-5 w-5" checked={fromTill} onChange={(e) => setFromTill(e.target.checked)} disabled={pending} />
          Paid from the till (records cash out of the drawer)
        </label>
      )}
      <div className="mt-3 space-y-2">
        <Msg msg={msg && !msg.ok ? msg : null} />
        <div className="flex flex-wrap gap-2">
          <button type="button" className="btn btn-primary px-4 text-sm" onClick={save} disabled={pending}>
            {pending ? "Saving…" : "Save payment"}
          </button>
          <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={pending}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
