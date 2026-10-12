"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { playNewTicketSound, unlockSound } from "../(app)/kitchen/sound";

export type ReadyOrder = { id: string; token: string; isToken: boolean; name: string; createdAt: string };

/** The board itself. It refreshes every 5 seconds and chimes when an order becomes ready (after one tap). */
export function ReadyBoard({ restaurant, preparing, ready }: { restaurant: string; preparing: ReadyOrder[]; ready: ReadyOrder[] }) {
  const router = useRouter();
  const seen = useRef<Set<string> | null>(null);
  const [fresh, setFresh] = useState<Set<string>>(new Set());
  const [soundOn, setSoundOn] = useState(false);

  useEffect(() => {
    const t = setInterval(() => router.refresh(), 5000);
    return () => clearInterval(t);
  }, [router]);

  // A newly ready order flashes for 10 seconds and plays the chime.
  useEffect(() => {
    const ids = new Set(ready.map((r) => r.id));
    const before = seen.current;
    seen.current = ids;
    if (!before) return;
    const added = [...ids].filter((id) => !before.has(id));
    if (added.length === 0) return;
    setFresh(new Set(added));
    if (soundOn) playNewTicketSound();
    const t = setTimeout(() => setFresh(new Set()), 10000);
    return () => clearTimeout(t);
  }, [ready, soundOn]);

  return (
    <main className="flex min-h-screen flex-col" style={{ background: "#111", color: "#fff" }}>
      <header className="flex items-center justify-between px-8 py-4">
        <div className="font-display text-3xl font-bold">{restaurant}</div>
        <button
          className="rounded-full border px-4 py-2 text-sm"
          style={{ borderColor: "rgba(255,255,255,.3)", color: "rgba(255,255,255,.8)" }}
          onClick={() => {
            unlockSound();
            setSoundOn((v) => !v);
          }}
        >
          {soundOn ? "Sound on" : "Tap for sound"}
        </button>
      </header>
      <div className="grid flex-1 grid-cols-1 gap-6 p-6 md:grid-cols-[2fr_3fr]">
        <section className="rounded-3xl p-6" style={{ background: "#1e1e1e" }}>
          <h1 className="mb-4 text-3xl font-bold" style={{ color: "#f5b942" }}>
            Preparing
          </h1>
          <ul className="grid grid-cols-2 gap-3 lg:grid-cols-3">
            {preparing.map((o) => (
              <li key={o.id} className="rounded-2xl px-3 py-3 text-center" style={{ background: "#2a2a2a" }}>
                <div className="font-display text-4xl font-bold tabular-nums">{o.token}</div>
                {o.name && <div className="truncate text-sm" style={{ color: "rgba(255,255,255,.7)" }}>{o.name}</div>}
              </li>
            ))}
          </ul>
          {preparing.length === 0 && <p style={{ color: "rgba(255,255,255,.5)" }}>—</p>}
        </section>
        <section className="rounded-3xl p-6" style={{ background: "#14361f" }}>
          <h1 className="mb-4 text-3xl font-bold" style={{ color: "#6ee08f" }}>
            Ready — please collect
          </h1>
          <ul className="grid grid-cols-2 gap-4 lg:grid-cols-3">
            {ready.map((o) => (
              <li
                key={o.id}
                className={`rounded-2xl px-3 py-4 text-center ${fresh.has(o.id) ? "animate-pulse" : ""}`}
                style={{ background: fresh.has(o.id) ? "#2fa35a" : "#1f5130" }}
              >
                <div className="font-display text-6xl font-bold tabular-nums">{o.token}</div>
                {o.name && <div className="truncate text-lg">{o.name}</div>}
              </li>
            ))}
          </ul>
          {ready.length === 0 && <p style={{ color: "rgba(255,255,255,.5)" }}>—</p>}
        </section>
      </div>
      <footer className="px-8 pb-4 text-xs" style={{ color: "rgba(255,255,255,.4)" }}>
        {preparing.some((o) => !o.isToken) || ready.some((o) => !o.isToken) ? "Number = the end of your bill number. " : ""}Updates by itself.
      </footer>
    </main>
  );
}
