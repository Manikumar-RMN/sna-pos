"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { setTicketStatus } from "./actions";

export type Ticket = {
  id: string;
  number: string;
  status: "new" | "preparing" | "ready";
  createdAt: string;
  where: string;
  items: { name: string; qty: number; note: string | null; cancelled: boolean }[];
};

const COLUMNS: { key: Ticket["status"]; title: string; next: "preparing" | "ready" | "served"; action: string }[] = [
  { key: "new", title: "New", next: "preparing", action: "Start" },
  { key: "preparing", title: "Preparing", next: "ready", action: "Ready" },
  { key: "ready", title: "Ready to serve", next: "served", action: "Served" },
];

function minutesAgo(iso: string, now: number) {
  return Math.max(0, Math.floor((now - new Date(iso).getTime()) / 60000));
}

export function KitchenBoard({ tickets, timezone }: { tickets: Ticket[]; timezone: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const t = setInterval(() => {
      setNow(Date.now());
      router.refresh();
    }, 15000);
    return () => clearInterval(t);
  }, [router]);

  function move(id: string, next: "preparing" | "ready" | "served") {
    setBusyId(id);
    setError(null);
    start(async () => {
      const res = await setTicketStatus(id, next);
      if (!res.ok) setError(res.error ?? "Could not update the ticket.");
      setBusyId(null);
      router.refresh();
    });
  }

  return (
    <>
      {error && (
        <p className="mb-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      <div className="grid gap-4 md:grid-cols-3">
        {COLUMNS.map((col) => {
          const list = tickets.filter((t) => t.status === col.key);
          return (
            <section key={col.key}>
              <h2 className="mb-2 text-sm font-bold">
                {col.title} <span style={{ color: "var(--color-ink-3)" }}>({list.length})</span>
              </h2>
              <div className="space-y-3">
                {list.length === 0 && (
                  <div className="rounded-xl border border-dashed p-4 text-center text-xs" style={{ borderColor: "var(--color-line)", color: "var(--color-ink-3)" }}>
                    Nothing here
                  </div>
                )}
                {list.map((t) => {
                  const age = minutesAgo(t.createdAt, now);
                  const late = col.key !== "ready" && age >= 15;
                  return (
                    <div key={t.id} className="card p-3" style={late ? { borderColor: "var(--color-bad)" } : undefined}>
                      <div className="mb-2 flex items-baseline justify-between gap-2">
                        <span className="text-sm font-bold">{t.where || t.number}</span>
                        <span className="text-xs tabular-nums" style={{ color: late ? "var(--color-bad)" : "var(--color-ink-3)" }}>
                          {age} min · {new Date(t.createdAt).toLocaleTimeString("en-IN", { timeZone: timezone, hour: "2-digit", minute: "2-digit" })}
                        </span>
                      </div>
                      <div className="mb-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                        {t.number}
                      </div>
                      <ul className="mb-3 space-y-1 text-sm">
                        {t.items.map((i, idx) => (
                          <li key={idx} style={i.cancelled ? { textDecoration: "line-through", color: "var(--color-bad)" } : undefined}>
                            <span className="font-bold tabular-nums">{i.qty}×</span> {i.name}
                            {i.cancelled && <span className="ml-1 text-[11px] font-bold no-underline">CANCELLED</span>}
                            {i.note && (
                              <div className="text-xs" style={{ color: "var(--color-warn)" }}>
                                {i.note}
                              </div>
                            )}
                          </li>
                        ))}
                      </ul>
                      <button
                        className="btn btn-primary h-11 w-full text-sm"
                        disabled={pending && busyId === t.id}
                        onClick={() => move(t.id, col.next)}
                      >
                        {pending && busyId === t.id ? "…" : col.action}
                      </button>
                    </div>
                  );
                })}
              </div>
            </section>
          );
        })}
      </div>
    </>
  );
}
