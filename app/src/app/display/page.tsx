"use client";

import { useEffect, useState } from "react";
import { money } from "@/lib/format";

type Line = { name: string; local: string | null; options: string | null; qty: number; amount: number };
type Msg = { restaurant: string; currency: string; lines: Line[]; total: number | null };

/**
 * Customer display: open it from the billing screen on the same computer and drag the window to the
 * screen that faces the guest. It shows the order as the cashier builds it, and the total.
 */
export default function CustomerDisplay() {
  const [msg, setMsg] = useState<Msg | null>(null);

  useEffect(() => {
    if (typeof BroadcastChannel === "undefined") return;
    const ch = new BroadcastChannel("sna-customer-display");
    ch.onmessage = (e) => setMsg(e.data as Msg);
    return () => ch.close();
  }, []);

  const lines = msg?.lines ?? [];
  const m = (n: number) => money(n, msg?.currency ?? "INR");

  return (
    <main className="flex min-h-screen flex-col" style={{ background: "var(--color-ground)" }}>
      <header className="px-8 py-5 text-white" style={{ background: "var(--color-brand)" }}>
        <div className="font-display text-3xl font-bold">{msg?.restaurant ?? "Welcome"}</div>
      </header>
      {lines.length === 0 ? (
        <div className="grid flex-1 place-items-center p-8 text-center">
          <div>
            <div className="font-display text-5xl font-bold">Welcome!</div>
            <p className="mt-3 text-xl" style={{ color: "var(--color-ink-3)" }}>
              Your order will appear here.
            </p>
          </div>
        </div>
      ) : (
        <div className="flex flex-1 flex-col p-8">
          <ul className="flex-1 space-y-3 text-2xl">
            {lines.map((l, i) => (
              <li key={i} className="flex items-start justify-between gap-6 border-b pb-3" style={{ borderColor: "var(--color-line)" }}>
                <div>
                  <span className="font-bold tabular-nums">{l.qty} ×</span> {l.name}
                  {l.local && <div className="text-lg" style={{ color: "var(--color-ink-3)" }}>{l.local}</div>}
                  {l.options && <div className="text-base" style={{ color: "var(--color-ink-3)" }}>{l.options}</div>}
                </div>
                <div className="tabular-nums">{m(l.amount)}</div>
              </li>
            ))}
          </ul>
          <div
            className="mt-6 flex items-center justify-between rounded-3xl px-8 py-6"
            style={{ background: "var(--color-accent)", color: "var(--color-accent-ink)" }}
          >
            <span className="text-3xl font-bold">Total</span>
            <span className="font-display text-5xl font-bold tabular-nums">{msg?.total != null ? m(msg.total) : "…"}</span>
          </div>
        </div>
      )}
    </main>
  );
}
