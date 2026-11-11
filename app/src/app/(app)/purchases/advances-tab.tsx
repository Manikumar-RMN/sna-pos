"use client";

import { useMemo, useRef, useState } from "react";
import { money } from "@/lib/format";
import { applyAdvance, cancelAdvance, payAdvance, unapplyAdvance } from "./actions";
import { amountCents, dayLabel, payMethods, refFor, type PayMethod, type SentRef } from "./helpers";
import { Badge, Confirm, Field, Msg, lineStyle, rowBtn, useRun } from "./ui";

export type AdvanceRow = {
  id: string;
  number: string;
  supplier: string;
  supplier_id: string;
  amount: number;
  used: number;
  left: number;
  method: string;
  reference: string | null;
  paid_on: string;
  from_till: boolean;
  status: string;
  notes: string | null;
  /** Bills this advance is sitting on, and the payment row to undo to take it back off. */
  onBills: { paymentId: string; receipt: string; amount: number }[];
};

export type OpenBill = { id: string; supplier_id: string; number: string; owed: number; received_on: string };

const STATUS: Record<string, { label: string; bg: string; fg: string }> = {
  open: { label: "Money left", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  used: { label: "Fully used", bg: "var(--color-surface-2)", fg: "var(--color-ink-2)" },
  cancelled: { label: "Cancelled", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
};

/**
 * Advance (on-account) money paid to suppliers: pay it, use it against a bill,
 * take it back off a bill, or cancel it if the supplier returned it.
 */
export function AdvancesTab({
  advances,
  suppliers,
  openBills,
  openTotal,
  currency,
  country,
  today,
  canTill,
}: {
  advances: AdvanceRow[];
  suppliers: { id: string; name: string }[];
  openBills: OpenBill[];
  openTotal: number;
  currency: string;
  country: string;
  today: string;
  /** This person may take cash out of the till (the "cash in / cash out" right). */
  canTill: boolean;
}) {
  const [adding, setAdding] = useState(false);
  const [using, setUsing] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const m = (n: number) => money(n, currency);

  return (
    <div className="space-y-5">
      <div className="card p-4">
        <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
          Advance money with suppliers
        </div>
        <div className="font-display mt-1 text-2xl font-bold tabular-nums">{m(openTotal)}</div>
        <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Money already paid that no bill has used yet. It shows in the supplier statement and in the Advance column of supplier ageing.
        </p>
      </div>

      {note && <Msg msg={{ ok: true, text: note }} />}

      {!adding ? (
        <button type="button" className="btn btn-primary px-5 text-sm" onClick={() => setAdding(true)} disabled={suppliers.length === 0}>
          Pay an advance
        </button>
      ) : (
        <AdvanceForm
          suppliers={suppliers}
          currency={currency}
          country={country}
          today={today}
          canTill={canTill}
          onDone={(text) => {
            setNote(text);
            setAdding(false);
          }}
          onClose={() => setAdding(false)}
        />
      )}

      <section>
        <h2 className="mb-2 text-sm font-bold">Advances paid</h2>
        {advances.length === 0 ? (
          <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
            No advance has been paid to a supplier yet.
          </div>
        ) : (
          <ul className="space-y-3">
            {advances.map((a) => (
              <AdvanceCard
                key={a.id}
                advance={a}
                bills={openBills.filter((b) => b.supplier_id === a.supplier_id)}
                currency={currency}
                open={using === a.id}
                onOpen={() => setUsing(using === a.id ? null : a.id)}
                onDone={(text) => {
                  setNote(text);
                  setUsing(null);
                }}
              />
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}

function AdvanceCard({
  advance: a,
  bills,
  currency,
  open,
  onOpen,
  onDone,
}: {
  advance: AdvanceRow;
  bills: OpenBill[];
  currency: string;
  open: boolean;
  onOpen: () => void;
  onDone: (text: string) => void;
}) {
  const { pending, msg, run } = useRun();
  const [why, setWhy] = useState("");
  const s = STATUS[a.status] ?? STATUS.open;
  const m = (n: number) => money(n, currency);

  return (
    <li className="card p-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <div className="font-display text-base font-bold">{a.supplier}</div>
          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            {a.number} · {dayLabel(a.paid_on)} · {a.method}
            {a.reference ? ` · ${a.reference}` : ""}
            {a.from_till ? " · from the till" : ""}
          </div>
          {a.notes && (
            <div className="mt-1 text-xs" style={{ color: "var(--color-ink-2)" }}>
              {a.notes}
            </div>
          )}
        </div>
        <Badge label={s.label} bg={s.bg} fg={s.fg} />
      </div>

      <div className="mt-3 grid gap-2 text-sm sm:grid-cols-3">
        <Figure label="Paid" value={m(a.amount)} />
        <Figure label="Used on bills" value={m(a.used)} />
        <Figure label="Left to use" value={m(a.status === "cancelled" ? 0 : a.left)} strong={a.status !== "cancelled" && a.left > 0} />
      </div>

      {a.onBills.length > 0 && (
        <ul className="mt-3 space-y-1.5 text-sm">
          {a.onBills.map((b) => (
            <li key={b.paymentId} className="flex flex-wrap items-center justify-between gap-2 rounded-xl border px-3 py-2" style={{ ...lineStyle, background: "var(--color-surface-2)" }}>
              <span>
                {m(b.amount)} on {b.receipt}
              </span>
              <Confirm question={`Put ${m(b.amount)} back on the account?`} yes="Put it back" disabled={pending} onYes={() => run(() => unapplyAdvance(b.paymentId, "Taken back off the bill from the Advances list"), (r) => onDone(r.message ?? "Put back."))}>
                Take off the bill
              </Confirm>
            </li>
          ))}
        </ul>
      )}

      <div className="mt-3 flex flex-wrap gap-2">
        {a.status === "open" && bills.length > 0 && (
          <button type="button" className={rowBtn} style={{ ...lineStyle, color: "var(--color-brand)" }} onClick={onOpen} disabled={pending}>
            {open ? "Close" : "Use on a bill"}
          </button>
        )}
        {a.status === "open" && bills.length === 0 && (
          <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Nothing is owed to {a.supplier} right now, so there is no bill to use it on.
          </span>
        )}
        {a.status === "open" && a.used === 0 && (
          <Confirm question="Cancel this advance?" yes="Cancel it" disabled={pending} onYes={() => run(() => cancelAdvance(a.id, why.trim().length >= 3 ? why : "Supplier returned the money"), (r) => onDone(r.message ?? "Cancelled."))}>
            Cancel
          </Confirm>
        )}
      </div>
      {a.status === "open" && a.used === 0 && (
        <Field label="Reason for cancelling" hint="(optional)" className="mt-2 max-w-sm">
          <input className="field h-10 text-sm" value={why} onChange={(e) => setWhy(e.target.value)} maxLength={300} placeholder="Supplier returned the money" disabled={pending} />
        </Field>
      )}

      {open && <UseForm advance={a} bills={bills} currency={currency} onDone={onDone} />}
      <div className="mt-2">
        <Msg msg={msg} />
      </div>
    </li>
  );
}

function Figure({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="rounded-xl border px-3 py-2" style={lineStyle}>
      <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
        {label}
      </div>
      <div className="tabular-nums" style={{ fontWeight: strong ? 700 : 400 }}>
        {value}
      </div>
    </div>
  );
}

function UseForm({ advance: a, bills, currency, onDone }: { advance: AdvanceRow; bills: OpenBill[]; currency: string; onDone: (text: string) => void }) {
  const { pending, msg, setMsg, run } = useRun();
  const sorted = useMemo(() => [...bills].sort((x, y) => x.received_on.localeCompare(y.received_on)), [bills]);
  const [billId, setBillId] = useState(sorted[0]?.id ?? "");
  const bill = sorted.find((b) => b.id === billId) ?? sorted[0];
  const suggested = Math.min(a.left, bill?.owed ?? 0);
  const [amount, setAmount] = useState(suggested.toFixed(2));
  const m = (n: number) => money(n, currency);

  function save() {
    if (!bill) return setMsg({ ok: false, text: "Choose the bill to use it on." });
    const cents = amountCents(amount);
    if (cents === null || cents <= 0) return setMsg({ ok: false, text: "Enter an amount greater than zero." });
    if (cents > Math.round(a.left * 100)) return setMsg({ ok: false, text: `Only ${m(a.left)} is left on ${a.number}.` });
    if (cents > Math.round(bill.owed * 100)) return setMsg({ ok: false, text: `Only ${m(bill.owed)} is still owed on ${bill.number}.` });
    run(() => applyAdvance({ advanceId: a.id, receiptId: bill.id, amount: cents / 100 }), (r) => {
      const text = r.receiptBalance > 0 ? `${m(r.amount)} of ${a.number} used on ${bill.number}. ${m(r.receiptBalance)} is still owed on it.` : `${m(r.amount)} of ${a.number} used on ${bill.number}. It is now fully paid.`;
      onDone(text);
      return text;
    });
  }

  return (
    <div className="mt-3 rounded-2xl border p-3" style={{ ...lineStyle, background: "var(--color-surface-2)" }}>
      <div className="text-sm font-bold">
        Use {a.number} on a bill ({m(a.left)} left)
      </div>
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <Field label="Bill">
          <select
            className="field h-10 text-sm"
            value={billId}
            onChange={(e) => {
              setBillId(e.target.value);
              const b = sorted.find((x) => x.id === e.target.value);
              if (b) setAmount(Math.min(a.left, b.owed).toFixed(2));
            }}
            disabled={pending}
          >
            {sorted.map((b) => (
              <option key={b.id} value={b.id}>
                {b.number} — {m(b.owed)} owed ({dayLabel(b.received_on)})
              </option>
            ))}
          </select>
        </Field>
        <Field label="Amount to use">
          <input className="field h-10 text-sm" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={pending} />
        </Field>
      </div>
      <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
        No cash moves now — the money left when the advance was paid. The bill is marked paid by that much.
      </p>
      <div className="mt-3 space-y-2">
        <Msg msg={msg && !msg.ok ? msg : null} />
        <button type="button" className="btn btn-primary px-4 text-sm" onClick={save} disabled={pending}>
          {pending ? "Saving…" : "Use on this bill"}
        </button>
      </div>
    </div>
  );
}

function AdvanceForm({
  suppliers,
  currency,
  country,
  today,
  canTill,
  onDone,
  onClose,
}: {
  suppliers: { id: string; name: string }[];
  currency: string;
  country: string;
  today: string;
  canTill: boolean;
  onDone: (text: string) => void;
  onClose: () => void;
}) {
  const { pending, msg, setMsg, run } = useRun();
  const methods = payMethods(country);
  const [supplierId, setSupplierId] = useState(suppliers[0]?.id ?? "");
  const [amount, setAmount] = useState("");
  const [method, setMethod] = useState<PayMethod>("bank");
  const [reference, setReference] = useState("");
  const [paidOn, setPaidOn] = useState(today);
  const [fromTill, setFromTill] = useState(false);
  const [notes, setNotes] = useState("");
  // The reference goes with what was sent: the same advance tried again keeps it, a changed one gets a new one.
  const sent = useRef<SentRef | null>(null);
  const m = (n: number) => money(n, currency);

  function save() {
    if (!supplierId) return setMsg({ ok: false, text: "Choose a supplier." });
    const cents = amountCents(amount);
    if (cents === null || cents <= 0) return setMsg({ ok: false, text: "Enter the amount paid." });
    if (!paidOn) return setMsg({ ok: false, text: "Choose the date it was paid." });
    const payload = { supplierId, amount: cents / 100, method, reference, paidOn, fromTill: method === "cash" && fromTill, notes };
    const mine = refFor(sent.current, payload);
    sent.current = mine;
    run(
      () => payAdvance({ ...payload, clientRef: mine.ref }),
      (r) => {
        // This reference is used up: anything saved after this is another advance.
        sent.current = null;
        const name = suppliers.find((s) => s.id === supplierId)?.name ?? "the supplier";
        const text = `${r.number} saved: ${m(r.amount)} paid to ${name} in advance.`;
        onDone(text);
        return text;
      },
      "Could not reach the server. Check the connection and tap Save advance again without changing anything — it will not be paid twice.",
    );
  }

  return (
    <div className="card p-4">
      <div className="text-sm font-bold">Pay an advance</div>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        For money given to a supplier before the goods or the bill arrive. Use it against a bill later.
      </p>
      <div className="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <Field label="Supplier">
          <select className="field h-10 text-sm" value={supplierId} onChange={(e) => setSupplierId(e.target.value)} disabled={pending}>
            {suppliers.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Amount paid">
          <input className="field h-10 text-sm" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" disabled={pending} />
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
        <Field label="Note" hint="(optional)">
          <input className="field h-10 text-sm" placeholder="What it is for" value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={300} disabled={pending} />
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
            {pending ? "Saving…" : "Save advance"}
          </button>
          <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={pending}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
