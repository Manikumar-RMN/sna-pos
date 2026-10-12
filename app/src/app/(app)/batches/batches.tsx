"use client";

import { useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ConfirmButton } from "../settings/confirm-button";
import { addBatch, writeOffBatch } from "./actions";

export type BatchData = {
  batches: { id: string; product_id: string; product: string; made_on: string; expires_on: string; qty_made: number; qty_left: number; wasted: number; note: string | null; expired: boolean }[];
  dishes: { id: string; name: string; left: number; short: number }[];
};

const iso = (d: Date) => d.toISOString().slice(0, 10);
const nice = (s: string) => new Date(s + "T00:00:00").toLocaleDateString("en-IN", { day: "numeric", month: "short" });

export function Batches({ data }: { data: BatchData }) {
  const router = useRouter();
  const [productId, setProductId] = useState(data.dishes[0]?.id ?? "");
  const [qty, setQty] = useState("");
  const [madeOn, setMadeOn] = useState(iso(new Date()));
  const [expires, setExpires] = useState(iso(new Date(Date.now() + 2 * 86400000)));
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const expired = data.batches.filter((b) => b.expired && b.qty_left > 0);

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <div>
        <h1 className="text-xl font-bold tracking-tight">Batches made</h1>
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          Ready-made goods counted in batches. Each sale takes from the oldest batch that has not expired.
        </p>
      </div>

      {data.dishes.length === 0 ? (
        <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          No dish is tracked in batches yet. In{" "}
          <Link href="/settings/menu" className="font-semibold" style={{ color: "var(--color-brand)" }}>
            Settings → Menu
          </Link>
          , edit a dish (for example Veg Puff) and tick &ldquo;Track in batches&rdquo;.
        </div>
      ) : (
        <>
          <section className="card p-4">
            <h2 className="mb-3 text-base font-bold">Record a batch</h2>
            <div className="grid gap-3 sm:grid-cols-5">
              <label className="text-sm font-semibold sm:col-span-2">
                Dish
                <select className="field mt-1" value={productId} onChange={(e) => setProductId(e.target.value)}>
                  {data.dishes.map((d) => (
                    <option key={d.id} value={d.id}>
                      {d.name}
                    </option>
                  ))}
                </select>
              </label>
              <label className="text-sm font-semibold">
                How many
                <input className="field mt-1" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} placeholder="24" />
              </label>
              <label className="text-sm font-semibold">
                Made on
                <input className="field mt-1" type="date" value={madeOn} onChange={(e) => setMadeOn(e.target.value)} />
              </label>
              <label className="text-sm font-semibold">
                Best before
                <input className="field mt-1" type="date" value={expires} onChange={(e) => setExpires(e.target.value)} />
              </label>
            </div>
            <div className="mt-3 flex flex-wrap items-center gap-2">
              <input className="field max-w-sm" placeholder="Note (optional), e.g. eggless" value={note} onChange={(e) => setNote(e.target.value)} maxLength={200} />
              <button
                className="btn btn-primary"
                disabled={pending || !productId}
                onClick={() =>
                  start(async () => {
                    const r = await addBatch(productId, Number(qty) || 0, expires, madeOn, note);
                    setMsg(r.error ? { ok: false, text: r.error } : { ok: true, text: "Batch recorded." });
                    if (!r.error) {
                      setQty("");
                      setNote("");
                      router.refresh();
                    }
                  })
                }
              >
                {pending ? "Saving…" : "Record batch"}
              </button>
            </div>
            {msg && (
              <p className="mt-2 text-sm" role="status" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
                {msg.text}
              </p>
            )}
          </section>

          <section className="card overflow-hidden">
            <div className="px-4 py-3 text-sm font-bold" style={{ borderBottom: "1px solid var(--color-line)" }}>
              Today
            </div>
            {data.dishes.map((d) => (
              <div key={d.id} className="flex items-center justify-between px-4 py-2.5 text-sm" style={{ borderBottom: "1px solid var(--color-line)" }}>
                <span className="font-medium">{d.name}</span>
                <span>
                  <b style={{ color: Number(d.left) > 0 ? "var(--color-ink)" : "var(--color-bad)" }}>{Number(d.left)}</b> left
                  {Number(d.short) > 0 && (
                    <span className="ml-2 rounded px-1.5 py-0.5 text-[11px] font-semibold" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                      {Number(d.short)} sold with no batch recorded
                    </span>
                  )}
                </span>
              </div>
            ))}
          </section>

          {expired.length > 0 && (
            <div className="rounded-2xl px-4 py-3 text-sm" role="note" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
              {expired.length} batch{expired.length === 1 ? " has" : "es have"} passed best before with stock left. Write them off below.
            </div>
          )}

          <section className="card overflow-hidden">
            <div className="px-4 py-3 text-sm font-bold" style={{ borderBottom: "1px solid var(--color-line)" }}>
              Batches
            </div>
            {data.batches.length === 0 && (
              <p className="px-4 py-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
                No open batches.
              </p>
            )}
            {data.batches.map((b) => (
              <div key={b.id} className="flex flex-wrap items-center justify-end gap-3 px-4 py-2.5 text-sm" style={{ borderBottom: "1px solid var(--color-line)" }}>
                <div className="min-w-0 flex-1">
                  <div className="font-medium">
                    {b.product}
                    {b.expired && b.qty_left > 0 && (
                      <span className="ml-2 rounded px-1.5 py-0.5 text-[11px] font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
                        Expired
                      </span>
                    )}
                  </div>
                  <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                    Made {nice(b.made_on)} · best before {nice(b.expires_on)} · made {Number(b.qty_made)}
                    {Number(b.wasted) > 0 && ` · written off ${Number(b.wasted)}`}
                    {b.note && ` · ${b.note}`}
                  </div>
                </div>
                <div className="font-semibold">{Number(b.qty_left)} left</div>
                {Number(b.qty_left) > 0 && (
                  <ConfirmButton
                    question={`Write off the ${Number(b.qty_left)} ${b.product} left in this batch?`}
                    yesLabel="Yes, write off"
                    disabled={pending}
                    onConfirm={() =>
                      start(async () => {
                        const r = await writeOffBatch(b.id);
                        setMsg(r.error ? { ok: false, text: r.error } : { ok: true, text: "Written off." });
                        if (!r.error) router.refresh();
                      })
                    }
                  >
                    Write off
                  </ConfirmButton>
                )}
              </div>
            ))}
          </section>
        </>
      )}
    </div>
  );
}
