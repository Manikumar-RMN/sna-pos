"use client";

import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { checkGiftCard, saveLoyaltyRules, sellGiftCard } from "./actions";

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

export function GiftCardDesk({ currency, methods }: { currency: string; methods: { id: string; name: string }[] }) {
  const [value, setValue] = useState("");
  const [method, setMethod] = useState(methods[0]?.id ?? "");
  const [phone, setPhone] = useState("");
  const [name, setName] = useState("");
  const [days, setDays] = useState("365");
  const [code, setCode] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
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
        <h2 className="text-sm font-bold">Check a gift card</h2>
        <div className="flex gap-2">
          <input className="field uppercase" placeholder="Code" value={code} onChange={(e) => setCode(e.target.value)} />
          <button
            className="btn border"
            style={{ borderColor: "var(--color-line)" }}
            disabled={pending || !code.trim()}
            onClick={() =>
              start(async () => {
                const r = await checkGiftCard(code);
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
      </div>
      {msg && <p role="status" className="text-sm font-semibold md:col-span-2" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>{msg.text}</p>}
    </section>
  );
}
