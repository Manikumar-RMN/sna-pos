"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { attachCustomer, redeemGiftCard, redeemPoints, redeemPointsDiscount, removePointsDiscount } from "./actions";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { useOnline } from "@/lib/use-online";
import { money } from "@/lib/format";
import { maxRedeemablePoints, pointsToAmount, redeemBlockedReason } from "./loyalty-math";

type Result = { ok: true; message?: string } | { ok: false; error: string };

export type RedeemSettings = {
  /** "discount" = points take money off the bill before tax; "tender" = points pay part of the bill (old way). */
  mode: "tender" | "discount";
  pointValue: number;
  minRedeem: number;
  maxPercent: number;
};

/** Guest on the bill (by phone) with their points; use points (as a discount or a payment) or a gift card while the bill is open. */
export function LoyaltyPanel({
  orderId,
  open,
  canPay,
  currency,
  guest,
  settings = { mode: "tender", pointValue: 0, minRedeem: 0, maxPercent: 100 },
  applied = { points: 0, discount: 0 },
  pool = 0,
  manualDiscount = 0,
  due = 0,
  senior = false,
  hasPayments = false,
}: {
  orderId: string;
  open: boolean;
  canPay: boolean;
  currency: string;
  guest: { name: string; phone: string; points: number } | null;
  settings?: RedeemSettings;
  /** Points already used as a discount on this bill. */
  applied?: { points: number; discount: number };
  /** Total of the lines that can take a discount. */
  pool?: number;
  /** Discount typed by hand on the bill. */
  manualDiscount?: number;
  /** Still to pay on the bill. */
  due?: number;
  senior?: boolean;
  hasPayments?: boolean;
}) {
  const router = useRouter();
  const online = useOnline();
  const [pending, start] = useTransition();
  const [phone, setPhone] = useState("");
  const [name, setName] = useState("");
  const [points, setPoints] = useState("");
  const [code, setCode] = useState("");
  const [amount, setAmount] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [approval, setApproval] = useState<null | { permission: string; retry: () => void }>(null);
  // Same id while the same request is retried (double tap, PIN retry); a new one after it is done. The server answers a repeat once.
  const redeemRef = useRef<{ key: string; id: string } | null>(null);

  const run = (fn: () => Promise<Result>) =>
    start(async () => {
      const r = await fn();
      if (!r.ok) {
        const need = neededRight(r.error);
        if (need) setApproval({ permission: need, retry: () => run(fn) });
        setMsg({ ok: false, text: cleanMessage(r.error) });
        return;
      }
      setMsg({ ok: true, text: r.message ?? "Saved." });
      router.refresh();
    });

  const discountMode = settings.mode === "discount";
  const limits = { balance: guest?.points ?? 0, pointValue: settings.pointValue, minRedeem: settings.minRedeem, maxPercent: settings.maxPercent, pool, manualDiscount, due };
  const maxPts = maxRedeemablePoints(limits);
  const blocked = redeemBlockedReason({ ...limits, senior, hasPayments });
  const typed = Math.floor(Number(points));
  const typedValid = Number.isFinite(typed) && typed > 0;

  function useDiscount() {
    const key = `${orderId}:${typed}`;
    if (redeemRef.current?.key !== key) redeemRef.current = { key, id: crypto.randomUUID() };
    const clientRef = redeemRef.current.id;
    run(async () => {
      const r = await redeemPointsDiscount({ orderId, points: typed, clientRef });
      if (r.ok) {
        redeemRef.current = null;
        setPoints("");
      }
      return r;
    });
  }

  return (
    <section className="card mb-4 space-y-3 p-4">
      {approval && (
        <ApprovalPrompt
          permission={approval.permission}
          onCancel={() => setApproval(null)}
          onApproved={(who) => {
            const retry = approval.retry;
            setApproval(null);
            setMsg({ ok: true, text: `Approved by ${who}.` });
            retry();
          }}
        />
      )}
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

      {/* Points used as a discount (before tax). */}
      {discountMode && applied.points > 0 && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-ground)" }}>
          <span>
            <b>{applied.points}</b> points used: <b>-{money(applied.discount, currency)}</b> off before tax
          </span>
          {open && !hasPayments && canPay && (
            <button
              className="btn border text-xs"
              style={{ borderColor: "var(--color-line)" }}
              disabled={pending || !online}
              onClick={() => run(() => removePointsDiscount(orderId))}
            >
              Remove points
            </button>
          )}
        </div>
      )}
      {discountMode && open && canPay && guest && applied.points === 0 && guest.points > 0 && (
        <div className="space-y-2">
          {!online ? (
            <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
              Using points needs internet.
            </p>
          ) : blocked ? (
            <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
              {blocked}
            </p>
          ) : (
            <>
              <div className="flex flex-wrap gap-2">
                <input
                  className="field w-32"
                  inputMode="numeric"
                  placeholder="Points"
                  aria-label="Points to use"
                  value={points}
                  onChange={(e) => setPoints(e.target.value.replace(/[^\d]/g, ""))}
                />
                <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={pending} onClick={() => setPoints(String(maxPts))}>
                  Max ({maxPts})
                </button>
                <button className="btn btn-primary" disabled={pending || !typedValid || typed > maxPts} onClick={useDiscount}>
                  Use points
                </button>
              </div>
              {typedValid && (
                <p className="text-xs" role="status" style={{ color: typed > maxPts ? "var(--color-bad)" : "var(--color-ink-2)" }}>
                  {typed > maxPts
                    ? `At most ${maxPts} points can be used on this bill.`
                    : `-${money(pointsToAmount(typed, settings.pointValue), currency)} off before tax`}
                </p>
              )}
              {settings.maxPercent < 100 && (
                <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  Points can pay up to {settings.maxPercent}% of the items that can be discounted.
                </p>
              )}
            </>
          )}
        </div>
      )}

      {/* Old way: points pay part of the bill. */}
      {!discountMode && open && canPay && guest && guest.points > 0 && (
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
