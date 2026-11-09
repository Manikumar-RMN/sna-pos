"use client";

import { useRef, useState } from "react";
import { money } from "@/lib/format";
import { returnGoods } from "./actions";
import type { ReceiptRow } from "./helpers";
import { Field, lineStyle, Msg, useRun } from "./ui";

/** Send goods from one receipt back to the supplier. Opens under the receipt it belongs to. */
export function ReturnForm({
  receipt,
  supplier,
  currency,
  onDone,
  onClose,
}: {
  receipt: ReceiptRow;
  supplier: string;
  currency: string;
  onDone: (text: string) => void;
  onClose: () => void;
}) {
  const { pending, msg, setMsg, run } = useRun();
  const [qty, setQty] = useState<Record<string, string>>({});
  const [reason, setReason] = useState("");
  // One reference per return: a second tap or a retry sends the same one, so it is saved once.
  const ref = useRef<string>(crypto.randomUUID());
  const m = (n: number) => money(n, currency);

  const picked = receipt.returnable
    .map((l) => ({ l, q: Number((qty[l.ingredient_id] ?? "").trim()) }))
    .filter((x) => Number.isFinite(x.q) && x.q > 0);
  const value = picked.reduce((a, x) => a + x.q * x.l.unit_cost, 0);

  function save() {
    for (const x of picked) {
      if (x.q > x.l.remaining) return setMsg({ ok: false, text: `Only ${x.l.remaining} ${x.l.unit} of ${x.l.name} can go back.` });
    }
    if (picked.length === 0) return setMsg({ ok: false, text: "Enter how much is going back." });
    if (reason.trim().length < 3) return setMsg({ ok: false, text: "Write a short reason for the return." });
    run(
      () => returnGoods({ receiptId: receipt.id, lines: picked.map((x) => ({ ingredient_id: x.l.ingredient_id, qty: x.q })), reason, clientRef: ref.current }),
      (r) => {
        ref.current = crypto.randomUUID();
        onDone(r.message);
        return r.message;
      },
      "Could not reach the server. Check the connection and tap Save return again without changing anything — it will not be saved twice.",
    );
  }

  return (
    <div className="mt-3 rounded-2xl border p-3" style={lineStyle}>
      <div className="text-sm font-bold">
        Return goods from {receipt.number} to {supplier}
      </div>
      <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
        The goods come out of stock and the amount owed goes down. Type only what is going back.
      </p>
      {receipt.returnable.length === 0 ? (
        <p className="mt-2 text-sm">Everything on this receipt has already gone back.</p>
      ) : (
        <ul className="mt-2 space-y-2">
          {receipt.returnable.map((l) => (
            <li key={l.ingredient_id} className="grid grid-cols-[minmax(0,1fr)_110px] items-center gap-2">
              <span className="min-w-0 text-sm">
                {l.name}
                <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
                  up to {l.remaining} {l.unit} · {m(l.unit_cost)} each
                </span>
              </span>
              <input
                className="field h-10 text-sm"
                inputMode="decimal"
                placeholder={`Qty (${l.unit})`}
                aria-label={`Quantity of ${l.name} going back`}
                value={qty[l.ingredient_id] ?? ""}
                onChange={(e) => setQty({ ...qty, [l.ingredient_id]: e.target.value })}
                disabled={pending}
              />
            </li>
          ))}
        </ul>
      )}
      <Field label="Why is it going back?" className="mt-3">
        <input className="field h-10 text-sm" placeholder="e.g. stale, wrong item, damaged" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} disabled={pending} />
      </Field>
      <div className="mt-2 text-sm">
        Value going back <b className="tabular-nums">{m(Math.round(value * 100) / 100)}</b>
      </div>
      <div className="mt-2">
        <Msg msg={msg && !msg.ok ? msg : null} />
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <button type="button" className="btn btn-primary px-4 text-sm" onClick={save} disabled={pending || receipt.returnable.length === 0}>
          {pending ? "Saving…" : "Save return"}
        </button>
        <button type="button" className="btn border px-4 text-sm" style={{ ...lineStyle, background: "var(--color-surface)" }} onClick={onClose} disabled={pending}>
          Close
        </button>
      </div>
    </div>
  );
}
