"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { attachCustomer, redeemGiftCard, redeemPoints } from "./actions";

/** Guest on the bill (by phone) with their points; redeem points or a gift card while the bill is open. */
export function LoyaltyPanel({
  orderId,
  open,
  canPay,
  currency,
  guest,
}: {
  orderId: string;
  open: boolean;
  canPay: boolean;
  currency: string;
  guest: { name: string; phone: string; points: number } | null;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [phone, setPhone] = useState("");
  const [name, setName] = useState("");
  const [points, setPoints] = useState("");
  const [code, setCode] = useState("");
  const [amount, setAmount] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const run = (fn: () => Promise<{ ok: true; message?: string } | { ok: false; error: string }>) =>
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
      if (r.ok) router.refresh();
    });

  return (
    <section className="card mb-4 space-y-3 p-4">
      <h2 className="text-sm font-bold">Loyalty and gift cards</h2>
      {guest ? (
        <p className="text-sm">
          Guest: <b>{guest.name}</b> · +{guest.phone} · <b>{guest.points}</b> points
        </p>
      ) : (
        <div className="flex flex-wrap gap-2">
          <input className="field min-w-0 flex-1" type="tel" inputMode="tel" placeholder="Guest phone" value={phone} onChange={(e) => setPhone(e.target.value)} />
          <input className="field min-w-0 flex-1" placeholder="Name (new guests)" value={name} onChange={(e) => setName(e.target.value)} />
          <button
            className="btn btn-primary"
            disabled={pending || !phone.trim()}
            onClick={() =>
              run(async () => {
                const r = await attachCustomer(orderId, phone, name);
                return r.ok ? { ok: true, message: `${r.name} added to the bill — ${r.points} points.` } : r;
              })
            }
          >
            Add guest
          </button>
        </div>
      )}
      {open && canPay && guest && guest.points > 0 && (
        <div className="flex flex-wrap gap-2">
          <input className="field w-32" inputMode="numeric" placeholder="Points" value={points} onChange={(e) => setPoints(e.target.value)} />
          <button className="btn border" style={{ borderColor: "var(--color-line)" }} disabled={pending || !Number(points)} onClick={() => run(() => redeemPoints(orderId, Number(points)))}>
            Redeem points
          </button>
        </div>
      )}
      {open && canPay && (
        <div className="flex flex-wrap gap-2">
          <input className="field w-40 uppercase" placeholder="Gift card code" value={code} onChange={(e) => setCode(e.target.value)} />
          <input className="field w-32" inputMode="decimal" placeholder={`Amount (${currency})`} value={amount} onChange={(e) => setAmount(e.target.value)} />
          <button
            className="btn border"
            style={{ borderColor: "var(--color-line)" }}
            disabled={pending || !code.trim()}
            onClick={() => run(() => redeemGiftCard(orderId, code, amount.trim() ? Number(amount) : null))}
          >
            Redeem gift card
          </button>
        </div>
      )}
      {open && canPay && <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>Leave the amount empty to use as much of the card as the bill needs.</p>}
      {msg && (
        <p role="status" className="text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </p>
      )}
    </section>
  );
}
