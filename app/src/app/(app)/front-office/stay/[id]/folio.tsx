"use client";

import { useRouter } from "next/navigation";
import { useRef, useState, useTransition } from "react";
import { money } from "@/lib/format";
import { MANUAL_CHARGE_KINDS, STATUS_LABEL, type Folio } from "@/lib/fo";
import { cancelStay, checkIn, checkOut, postCharge, takePayment, voidCharge, voidPayment } from "../../actions";

type Method = { id: string; name: string };

export function FolioView({ folio, methods, currency, canManage }: { folio: Folio; methods: Method[]; currency: string; canManage: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const { stay, totals } = folio;
  const open = stay.status === "reserved" || stay.status === "inhouse";
  const owes = totals.balance > 0;
  const credit = totals.balance < 0;

  const [kind, setKind] = useState("food");
  const [desc, setDesc] = useState("");
  const [amt, setAmt] = useState("");
  const [qty, setQty] = useState("1");
  const [pay, setPay] = useState("");
  const [method, setMethod] = useState(methods[0]?.id ?? "");
  const chargeRef = useRef(crypto.randomUUID());
  const payRef = useRef(crypto.randomUUID());
  const outRef = useRef(crypto.randomUUID());

  function act(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Done." } : { ok: false, text: r.error ?? "That did not work." });
      if (r.ok) {
        after?.();
        router.refresh();
      }
    });
  }
  const ask = (q: string) => {
    const r = window.prompt(q);
    return r && r.trim() ? r.trim() : null;
  };

  return (
    <div className="mt-2 space-y-4">
      <header className="card p-4">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h1 className="text-xl font-extrabold">{stay.guest.full_name}</h1>
            <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              Stay #{stay.stay_no} · {stay.room_type}{stay.room_number ? ` · Room ${stay.room_number}` : ""} · {stay.arrival} → {stay.departure} ({stay.nights} night{stay.nights === 1 ? "" : "s"}) · {money(stay.nightly_rate, currency)}/night
            </p>
            {stay.guest.phone && <p className="text-sm">{stay.guest.phone}</p>}
          </div>
          <span className="rounded-full px-3 py-1 text-xs font-bold" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)" }}>{STATUS_LABEL[stay.status]}</span>
        </div>
      </header>

      {msg && (
        <div role="status" className="rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>
          {msg.text}
        </div>
      )}

      <section className="card p-4">
        <h2 className="text-sm font-bold">Charges</h2>
        <ul className="mt-2 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
          {folio.charges.length === 0 && <li className="py-2" style={{ color: "var(--color-ink-3)" }}>Nothing posted yet. Room charges appear after each night audit.</li>}
          {folio.charges.map((c) => (
            <li key={c.charge_id} className="flex items-center justify-between gap-2 py-2" style={c.voided ? { opacity: 0.5, textDecoration: "line-through" } : undefined}>
              <span>{c.on} · {c.description}{c.order_id ? " (restaurant bill)" : ""}<span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>{money(c.net_amount, currency)} + tax {money(c.tax_amount, currency)}{c.void_reason ? ` · voided: ${c.void_reason}` : ""}</span></span>
              <span className="flex items-center gap-2">
                <b>{money(c.total, currency)}</b>
                {canManage && open && !c.voided && !c.order_id && (
                  <button className="text-xs underline" disabled={pending} onClick={() => { const r = ask("Why are you voiding this charge?"); if (r) act(() => voidCharge(stay.stay_id, c.charge_id, r)); }}>Void</button>
                )}
              </span>
            </li>
          ))}
        </ul>
        {canManage && open && (
          <div className="mt-3 grid gap-2 sm:grid-cols-[1fr_2fr_1fr_80px_auto]">
            <select className="field h-10 text-sm" value={kind} onChange={(e) => setKind(e.target.value)} aria-label="Charge type">
              {MANUAL_CHARGE_KINDS.map((k) => <option key={k.value} value={k.value}>{k.label}</option>)}
            </select>
            <input className="field h-10 text-sm" placeholder="Description" value={desc} onChange={(e) => setDesc(e.target.value)} aria-label="Description" />
            <input className="field h-10 text-sm" inputMode="decimal" placeholder="Amount" value={amt} onChange={(e) => setAmt(e.target.value)} aria-label="Amount before tax" />
            <input className="field h-10 text-sm" inputMode="decimal" placeholder="Qty" value={qty} onChange={(e) => setQty(e.target.value)} aria-label="Quantity" />
            <button
              className="btn btn-primary h-10 min-h-0 px-4 text-sm"
              disabled={pending || !desc.trim() || !(Number(amt) >= 0) || amt.trim() === "" || !(Number(qty) > 0)}
              onClick={() => act(() => postCharge(stay.stay_id, kind, desc, Number(amt), Number(qty), chargeRef.current), () => { chargeRef.current = crypto.randomUUID(); setDesc(""); setAmt(""); setQty("1"); })}
            >Post</button>
          </div>
        )}
      </section>

      <section className="card p-4">
        <h2 className="text-sm font-bold">Payments</h2>
        <ul className="mt-2 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
          {folio.payments.length === 0 && <li className="py-2" style={{ color: "var(--color-ink-3)" }}>No payments yet.</li>}
          {folio.payments.map((p) => (
            <li key={p.payment_id} className="flex items-center justify-between gap-2 py-2" style={p.voided ? { opacity: 0.5, textDecoration: "line-through" } : undefined}>
              <span>{p.on} · {p.is_refund ? "Refund" : "Payment"} · {p.method}{p.void_reason ? ` · voided: ${p.void_reason}` : ""}</span>
              <span className="flex items-center gap-2">
                <b>{p.is_refund ? "−" : ""}{money(p.amount, currency)}</b>
                {canManage && stay.status !== "checked_out" && !p.voided && (
                  <button className="text-xs underline" disabled={pending} onClick={() => { const r = ask("Why are you voiding this payment?"); if (r) act(() => voidPayment(stay.stay_id, p.payment_id, r)); }}>Void</button>
                )}
              </span>
            </li>
          ))}
        </ul>
        {canManage && stay.status !== "checked_out" && stay.status !== "cancelled" && (
          <div className="mt-3 flex flex-wrap items-center gap-2">
            <select className="field h-10 text-sm" value={method} onChange={(e) => setMethod(e.target.value)} aria-label="Payment method">
              {methods.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
            </select>
            <input className="field h-10 w-32 text-sm" inputMode="decimal" placeholder={owes ? String(totals.balance) : "Amount"} value={pay} onChange={(e) => setPay(e.target.value)} aria-label="Amount" />
            <button className="btn btn-pay h-10 min-h-0 px-4 text-sm" disabled={pending || !(Number(pay) > 0) || !method} onClick={() => act(() => takePayment(stay.stay_id, Number(pay), method, false, payRef.current), () => { payRef.current = crypto.randomUUID(); setPay(""); })}>Take payment</button>
            {credit && (
              <button className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }} disabled={pending || !method} onClick={() => act(() => takePayment(stay.stay_id, -totals.balance, method, true, crypto.randomUUID()))}>Refund {money(-totals.balance, currency)}</button>
            )}
          </div>
        )}
      </section>

      <section className="card flex flex-wrap items-center justify-between gap-3 p-4">
        <div>
          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>Charged {money(totals.charged, currency)} · Paid {money(totals.paid, currency)}{totals.refunded > 0 ? ` · Refunded ${money(totals.refunded, currency)}` : ""}</div>
          <b className="text-xl" style={{ color: owes ? "var(--color-bad)" : credit ? "var(--color-warn)" : "var(--color-ok)" }}>
            {owes ? `Owes ${money(totals.balance, currency)}` : credit ? `In credit ${money(-totals.balance, currency)}` : "Settled"}
          </b>
        </div>
        {canManage && (
          <div className="flex flex-wrap gap-2">
            {stay.status === "reserved" && (
              <>
                <button className="btn btn-pay h-11 min-h-0 px-5 text-sm" disabled={pending} onClick={() => act(() => checkIn(stay.stay_id, null))}>Check in</button>
                <button className="btn h-11 min-h-0 px-5 text-sm" style={{ border: "1px solid var(--color-line)" }} disabled={pending} onClick={() => { const r = ask("Reason for cancelling?"); if (r) act(() => cancelStay(stay.stay_id, r)); }}>Cancel booking</button>
              </>
            )}
            {stay.status === "inhouse" && (
              <button
                className="btn btn-pay h-11 min-h-0 px-5 text-sm"
                disabled={pending || credit || (owes && !method)}
                title={credit ? "Refund the credit first" : undefined}
                onClick={() => act(() => checkOut(stay.stay_id, owes ? method : null, outRef.current))}
              >
                {owes ? `Collect ${money(totals.balance, currency)} and check out` : "Check out"}
              </button>
            )}
          </div>
        )}
      </section>
    </div>
  );
}
