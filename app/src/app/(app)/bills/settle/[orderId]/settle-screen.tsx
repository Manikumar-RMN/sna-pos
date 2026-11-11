"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { money } from "@/lib/format";
import { payBill } from "../../actions";

export type CheckCard = { id: string; billNumber: string; amount: number; balance: number; covers: number | null };
export type PayMethod = { id: string; name: string; kind: string; askReference: boolean };
type BillLine = { name: string; qty: number; amount: number };
/** One payment waiting on this screen. Nothing is sent until Settle is pressed, so a line can still be taken off. */
type Staged = { key: string; methodId: string; methodName: string; amount: number; narration: string; tip: number };

/**
 * Winsar's Settlement screen. Left: the open checks of this table. Middle: the payments being taken, each removable,
 * under the payment buttons. Right: the balance, the items and the totals. Settle sends them all, in order.
 */
export function SettleScreen({
  orderId,
  tableNumber,
  currency,
  checks,
  lines,
  value,
  discount,
  taxes,
  total,
  balance,
  methods,
  canPay,
  dayClosed,
}: {
  orderId: string;
  tableNumber: string | null;
  currency: string;
  checks: CheckCard[];
  lines: BillLine[];
  value: number;
  discount: number;
  taxes: number;
  total: number;
  balance: number;
  methods: PayMethod[];
  canPay: boolean;
  dayClosed: boolean;
}) {
  const router = useRouter();
  const m = (n: number) => money(n, currency);
  const [staged, setStaged] = useState<Staged[]>([]);
  const [open, setOpen] = useState<PayMethod | null>(null);
  const [amount, setAmount] = useState("");
  const [narration, setNarration] = useState("");
  const [tip, setTip] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const taken = staged.reduce((s, p) => s + p.amount, 0);
  const left = Math.round((balance - taken) * 100) / 100;

  function openPay(p: PayMethod) {
    setError(null);
    setOpen(p);
    setAmount(left > 0 ? left.toFixed(2) : "");
    setNarration("");
    setTip("");
  }

  function addNow() {
    const n = Number(amount);
    if (!(n > 0)) return setError("Enter the amount.");
    if (n > left + 0.001) return setError(`Only ${m(left)} is left to pay.`);
    setStaged((xs) => [
      ...xs,
      { key: crypto.randomUUID(), methodId: open!.id, methodName: open!.name, amount: Math.round(n * 100) / 100, narration: narration.trim().slice(0, 60), tip: Number(tip) > 0 ? Number(tip) : 0 },
    ]);
    setOpen(null);
    setError(null);
  }

  function settle() {
    if (staged.length === 0) return setError("Add a payment first.");
    setError(null);
    start(async () => {
      for (let i = 0; i < staged.length; i++) {
        const p = staged[i];
        let res: Awaited<ReturnType<typeof payBill>>;
        try {
          res = await payBill({
            orderId,
            paymentMethodId: p.methodId,
            tendered: null,
            amount: p.amount,
            reference: p.narration || null,
            clientRef: p.key,
            ...(p.tip > 0 ? { tip: p.tip } : {}),
          });
        } catch {
          return setError(`The internet dropped. ${i} of ${staged.length} payments went through; open the bill to see where it stands.`);
        }
        if (!res.ok) {
          setStaged((xs) => xs.slice(i));
          return setError(`${res.error} (${i} of ${staged.length} payments went through; the rest are still waiting here.)`);
        }
      }
      setStaged([]);
      setDone("Settled.");
      router.push(`/bills/${orderId}?from=pos`);
      router.refresh();
    });
  }

  const blocked = !canPay ? "You do not have permission to take payments." : dayClosed ? "This bill's day is closed." : balance <= 0 ? "This bill is already paid." : null;

  return (
    <div className="flex min-h-[calc(100dvh-7rem)] flex-col">
      <div className="mb-2 flex items-center justify-between">
        <h1 className="text-base font-bold">
          {tableNumber ? `Table No : ${tableNumber}` : "Counter"} <span style={{ color: "var(--color-ink-3)" }}>· Settlement</span>
        </h1>
        <Link href={`/bills/${orderId}?from=pos`} className="btn border text-sm" style={{ borderColor: "var(--color-line)" }}>
          ‹ Back
        </Link>
      </div>

      {blocked && (
        <p className="mb-2 rounded-lg px-3 py-2 text-sm font-semibold" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
          {blocked}
        </p>
      )}

      <div className="grid min-h-0 flex-1 gap-3 lg:grid-cols-[230px_minmax(0,1fr)_260px]">
        {/* Left: the open checks of this table */}
        <section className="card min-h-0 overflow-y-auto p-2" aria-label="Check list">
          <h2 className="mb-2 text-xs font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
            Check list
          </h2>
          {checks.map((c) => {
            const here = c.id === orderId;
            return (
              <Link
                key={c.id}
                href={`/bills/settle/${c.id}`}
                className="mb-1.5 block rounded-lg border p-2 text-sm"
                style={{ borderColor: here ? "var(--color-brand)" : "var(--color-line)", background: here ? "var(--color-brand-soft)" : undefined }}
              >
                <div className="flex items-center justify-between">
                  <span className="font-bold">Check {c.billNumber}</span>
                  {here && (
                    <span className="rounded px-1 text-[10px] font-bold" style={{ background: "var(--color-brand)", color: "#fff" }}>
                      Selected
                    </span>
                  )}
                </div>
                <div style={{ color: "var(--color-ink-2)" }}>Amount {m(c.amount)}</div>
                <div style={{ color: "var(--color-ink-3)" }}>
                  {c.covers != null ? `Cover ${c.covers} · ` : ""}
                  {c.balance > 0 ? `${m(c.balance)} to pay` : "paid"}
                </div>
              </Link>
            );
          })}
        </section>

        {/* Middle: the payments being taken, then the payment buttons */}
        <section className="card flex min-h-0 flex-col p-2" aria-label="Settlement details">
          <div className="mb-2 flex items-center justify-between">
            <h2 className="text-xs font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
              Settlement details
            </h2>
            <span className="text-sm font-bold">
              Total <span style={{ color: "var(--color-bad)" }}>{m(balance)}</span>
            </span>
          </div>

          <ul className="min-h-0 flex-1 space-y-1.5 overflow-y-auto">
            {staged.length === 0 && (
              <li className="py-8 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                No payment added yet. Nothing is taken until you press Settle.
              </li>
            )}
            {staged.map((p) => (
              <li key={p.key} className="flex items-center gap-2 rounded-lg border px-2 py-2 text-sm" style={{ borderColor: "var(--color-line)" }}>
                <span className="min-w-0 flex-1">
                  <b>Pay Mode : {p.methodName}</b>
                  <br />
                  <span style={{ color: "var(--color-ink-3)" }}>
                    {p.narration ? p.narration : "No narration"}
                    {p.tip > 0 ? ` · tip ${m(p.tip)}` : ""}
                  </span>
                </span>
                <span className="font-bold" style={{ color: "var(--color-brand-strong)" }}>
                  {m(p.amount)}
                </span>
                <button
                  type="button"
                  aria-label={`Take off the ${p.methodName} payment`}
                  className="rounded-md border px-2 py-1 text-xs font-bold"
                  style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }}
                  onClick={() => setStaged((xs) => xs.filter((x) => x.key !== p.key))}
                >
                  ✕
                </button>
              </li>
            ))}
          </ul>

          <div className="mt-2 grid grid-cols-3 gap-1.5">
            {methods.map((p) => (
              <button
                key={p.id}
                type="button"
                disabled={!!blocked || left <= 0}
                onClick={() => openPay(p)}
                className="min-h-11 rounded-lg border text-sm font-semibold disabled:opacity-40"
                style={{ borderColor: "var(--color-brand)", color: "var(--color-brand-strong)" }}
              >
                {p.name}
              </button>
            ))}
          </div>
        </section>

        {/* Right: the balance, the items and the totals */}
        <section className="card flex min-h-0 flex-col p-2" aria-label="Check details">
          <div className="mb-2 flex items-center justify-between">
            <h2 className="text-xs font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
              Check details
            </h2>
            <span className="text-sm font-bold">
              Bal <span style={{ color: left <= 0 ? "var(--color-ok)" : "var(--color-bad)" }}>{m(left)}</span>
            </span>
          </div>
          <div className="min-h-0 flex-1 overflow-y-auto rounded-lg border" style={{ borderColor: "var(--color-line)" }}>
            <div className="grid grid-cols-[32px_1fr_70px] gap-1 px-2 py-1 text-[11px] font-bold" style={{ background: "var(--color-surface-2)" }}>
              <span>Qty</span>
              <span>Description</span>
              <span className="text-right">Amount</span>
            </div>
            {lines.map((l, i) => (
              <div key={i} className="grid grid-cols-[32px_1fr_70px] gap-1 px-2 py-1 text-sm" style={{ borderTop: "1px solid var(--color-line)" }}>
                <span>{l.qty}</span>
                <span className="truncate">{l.name}</span>
                <span className="text-right">{m(l.amount)}</span>
              </div>
            ))}
          </div>
          <dl className="mt-2 space-y-0.5 text-sm">
            <div className="flex justify-between">
              <dt style={{ color: "var(--color-ink-3)" }}>Check value</dt>
              <dd>{m(value)}</dd>
            </div>
            <div className="flex justify-between">
              <dt style={{ color: "var(--color-ink-3)" }}>Discount</dt>
              <dd>{m(discount)}</dd>
            </div>
            <div className="flex justify-between">
              <dt style={{ color: "var(--color-ink-3)" }}>Taxes</dt>
              <dd>{m(taxes)}</dd>
            </div>
            <div className="flex justify-between border-t pt-1 font-bold" style={{ borderColor: "var(--color-line)" }}>
              <dt>Total</dt>
              <dd>{m(total)}</dd>
            </div>
          </dl>
          <button
            type="button"
            className="btn btn-pay mt-2 w-full text-base"
            disabled={!!blocked || pending || staged.length === 0}
            onClick={settle}
          >
            {pending ? "Settling…" : left <= 0 ? "Settle" : `Settle (${m(left)} still to pay)`}
          </button>
        </section>
      </div>

      {error && (
        <p className="mt-2 rounded-lg px-3 py-2 text-sm font-semibold" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      {done && !error && (
        <p className="mt-2 text-sm font-semibold" role="status" style={{ color: "var(--color-ok)" }}>
          {done}
        </p>
      )}

      {open && (
        <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" role="dialog" aria-label={`Pay by ${open.name}`}>
          <div className="w-full max-w-sm rounded-xl p-4" style={{ background: "var(--color-surface)" }}>
            <div className="mb-3 text-center text-sm font-bold">Pay Mode : {open.name}</div>
            <label className="text-xs font-semibold" htmlFor="pm-amt">
              Amount
            </label>
            <input id="pm-amt" className="field mb-2 h-10 w-full text-sm" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ""))} />
            <label className="text-xs font-semibold" htmlFor="pm-nar">
              Narration{open.askReference ? " (reference)" : ""}
            </label>
            <input id="pm-nar" className="field mb-2 h-10 w-full text-sm" maxLength={60} value={narration} onChange={(e) => setNarration(e.target.value)} />
            <label className="text-xs font-semibold" htmlFor="pm-tip">
              Tips
            </label>
            <input id="pm-tip" className="field mb-3 h-10 w-full text-sm" inputMode="decimal" value={tip} onChange={(e) => setTip(e.target.value.replace(/[^0-9.]/g, ""))} />
            {error && (
              <p className="mb-2 text-xs" style={{ color: "var(--color-bad)" }}>
                {error}
              </p>
            )}
            <div className="flex justify-end gap-2">
              <button type="button" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setOpen(null)}>
                ‹ Back
              </button>
              <button type="button" className="btn btn-primary px-6 text-sm" onClick={addNow}>
                Add Now
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
