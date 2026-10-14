"use client";

import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { checkGiftCard, giftCardHistory, payBackGiftCard, saveLoyaltyRules, sellGiftCard, topUpGiftCard, type CardEntry } from "./actions";

import { useTz } from "../tz";
export function LoyaltyRules({ currency, initial }: { currency: string; initial: { spend: number; value: number; min: number; saved: boolean } }) {
  const [spend, setSpend] = useState(String(initial.spend));
  const [value, setValue] = useState(String(initial.value));
  const [min, setMin] = useState(String(initial.min));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  return (
    <section className="card space-y-3 p-4">
      <h2 className="text-sm font-bold">Points rules {!initial.saved && <span style={{ color: "var(--color-warn)" }}>— not set yet, guests earn nothing until you save</span>}</h2>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="block text-sm">
          <span className="mb-1 block font-semibold">1 point for every ({currency})</span>
          <input className="field" inputMode="decimal" value={spend} onChange={(e) => setSpend(e.target.value)} />
        </label>
        <label className="block text-sm">
          <span className="mb-1 block font-semibold">1 point is worth ({currency})</span>
          <input className="field" inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value)} />
        </label>
        <label className="block text-sm">
          <span className="mb-1 block font-semibold">Least points to use at once</span>
          <input className="field" inputMode="numeric" value={min} onChange={(e) => setMin(e.target.value)} />
        </label>
      </div>
      <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
        Example: with {spend || "100"} and {value || "1"}, a bill of {money(Number(spend || 100) * 10, currency)} earns 10 points, worth{" "}
        {money(10 * Number(value || 1), currency)} on a later bill. A credit note takes back the points on the refunded part.
      </p>
      <button
        className="btn btn-primary"
        disabled={pending}
        onClick={() =>
          start(async () => {
            const r = await saveLoyaltyRules(Number(spend), Number(value), Number(min || 0));
            setMsg(r.ok ? { ok: true, text: r.message } : { ok: false, text: r.error });
          })
        }
      >
        Save rules
      </button>
      {msg && <p role="status" className="text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>{msg.text}</p>}
    </section>
  );
}

export function GiftCardDesk({ currency, methods, canPayBack = false }: { currency: string; methods: { id: string; name: string }[]; canPayBack?: boolean }) {
  const tz = useTz();
  const [value, setValue] = useState("");
  const [method, setMethod] = useState(methods[0]?.id ?? "");
  const [phone, setPhone] = useState("");
  const [name, setName] = useState("");
  const [days, setDays] = useState("365");
  const [code, setCode] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [card, setCard] = useState<{ code: string; balance: number; entries: CardEntry[] } | null>(null);
  const [topUp, setTopUp] = useState("");
  const [topMethod, setTopMethod] = useState(methods[0]?.id ?? "");
  const [confirmBack, setConfirmBack] = useState(false);
  const refresh = async (c: string) => {
    const h = await giftCardHistory(c);
    setCard(h.ok ? { code: h.code, balance: h.balance, entries: h.entries } : null);
  };
  const kindLabel: Record<CardEntry["kind"], string> = { issue: "Sold", topup: "Topped up", redeem: "Paid bill", payback: "Paid back", void: "Bill voided, money returned" };
  const [pending, start] = useTransition();
  const m = (n: number) => money(n, currency);
  return (
    <section className="card grid gap-4 p-4 md:grid-cols-2">
      <div className="space-y-2">
        <h2 className="text-sm font-bold">Sell a gift card</h2>
        <div className="flex gap-2">
          <input className="field" inputMode="decimal" placeholder={`Value (${currency})`} value={value} onChange={(e) => setValue(e.target.value)} />
          <select className="field" value={method} onChange={(e) => setMethod(e.target.value)} aria-label="Paid by">
            {methods.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
          </select>
        </div>
        <div className="flex gap-2">
          <input className="field" type="tel" placeholder="Buyer phone (optional)" value={phone} onChange={(e) => setPhone(e.target.value)} />
          <input className="field" placeholder="Name (optional)" value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <label className="flex items-center gap-2 text-sm">
          Valid for <input className="field w-24" inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value)} /> days (0 = never expires)
        </label>
        <button
          className="btn btn-pay"
          disabled={pending || !Number(value) || !method}
          onClick={() =>
            start(async () => {
              const r = await sellGiftCard(Number(value), method, phone, name, Number(days || 0));
              setMsg(r.ok ? { ok: true, text: `Gift card ${r.code} for ${m(r.value)} sold${r.expires ? `, valid till ${r.expires}` : ""}. Give the code to the guest.` } : { ok: false, text: r.error });
              if (r.ok) setValue("");
            })
          }
        >
          Sell gift card
        </button>
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>Cash for a gift card is added to the drawer of the open shift. It is not a sale; tax is charged when the card is used on a bill.</p>
      </div>
      <div className="space-y-2">
        <h2 className="text-sm font-bold">Check, top up or pay back a card</h2>
        <div className="flex gap-2">
          <input className="field uppercase" placeholder="Code" value={code} onChange={(e) => setCode(e.target.value)} />
          <button
            className="btn border"
            style={{ borderColor: "var(--color-line)" }}
            disabled={pending || !code.trim()}
            onClick={() =>
              start(async () => {
                const r = await checkGiftCard(code);
                setConfirmBack(false);
                if (r.ok) await refresh(r.code);
                else setCard(null);
                setMsg(
                  r.ok
                    ? { ok: !r.expired, text: `${r.code}: ${m(Number(r.balance))} left of ${m(Number(r.value))}${r.expires_on ? ` · expires ${r.expires_on}` : ""}${r.expired ? " · EXPIRED" : ""}` }
                    : { ok: false, text: r.error },
                );
              })
            }
          >
            Check
          </button>
        </div>
        {card && (
          <div className="space-y-2 rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
            <div className="text-sm">
              <b>{card.code}</b> · balance <b>{m(card.balance)}</b>
            </div>
            <div className="flex flex-wrap gap-2">
              <input className="field w-28" inputMode="decimal" placeholder="Add amount" value={topUp} onChange={(e) => setTopUp(e.target.value)} aria-label="Amount to add" />
              <select className="field w-36" value={topMethod} onChange={(e) => setTopMethod(e.target.value)} aria-label="Paid by">
                {methods.map((x) => <option key={x.id} value={x.id}>{x.name}</option>)}
              </select>
              <button
                className="btn btn-pay"
                disabled={pending || !Number(topUp) || !topMethod}
                onClick={() =>
                  start(async () => {
                    const r = await topUpGiftCard(card.code, Number(topUp), topMethod);
                    setMsg(r.ok ? { ok: true, text: `${m(r.added)} added to ${r.code}. New balance ${m(r.balance)}.` } : { ok: false, text: r.error });
                    if (r.ok) {
                      setTopUp("");
                      await refresh(card.code);
                    }
                  })
                }
              >
                Top up
              </button>
            </div>
            {canPayBack && card.balance > 0 && (
              <div className="flex flex-wrap items-center gap-2">
                {!confirmBack ? (
                  <button className="btn border" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirmBack(true)}>
                    Pay back {m(card.balance)} in cash
                  </button>
                ) : (
                  <>
                    <span className="text-sm">Give {m(card.balance)} cash and take the card back?</span>
                    <button
                      className="btn btn-primary"
                      disabled={pending}
                      onClick={() =>
                        start(async () => {
                          const r = await payBackGiftCard(card.code);
                          setConfirmBack(false);
                          setMsg(r.ok ? { ok: true, text: `${m(r.paidBack)} paid back. Card ${r.code} is now empty.` } : { ok: false, text: r.error });
                          if (r.ok) await refresh(card.code);
                        })
                      }
                    >
                      Yes, pay back
                    </button>
                    <button className="btn" onClick={() => setConfirmBack(false)}>No</button>
                  </>
                )}
              </div>
            )}
            {card.entries.length > 0 && (
              <ul className="max-h-48 space-y-0.5 overflow-y-auto text-xs" style={{ color: "var(--color-ink-2)" }}>
                {card.entries.map((e, i) => (
                  <li key={i} className="flex justify-between gap-2">
                    <span>
                      {new Date(e.at).toLocaleString("en-IN", { timeZone: tz, dateStyle: "short", timeStyle: "short" })} · {kindLabel[e.kind]}
                      {e.bill ? ` · ${e.bill}` : ""}
                    </span>
                    <span className="tabular-nums">{Number(e.amount) > 0 ? "+" : "−"}{m(Math.abs(Number(e.amount)))}</span>
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          Prepaid cards for food courts and canteens: sell a card with &ldquo;0 = never expires&rdquo;, top it up whenever the guest pays in, and use it on any bill.
          Paying back the unused balance takes the cash out of the drawer.
        </p>
      </div>
      {msg && <p role="status" className="text-sm font-semibold md:col-span-2" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>{msg.text}</p>}
    </section>
  );
}
