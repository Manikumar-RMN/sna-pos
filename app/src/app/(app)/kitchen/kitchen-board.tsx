"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { printedTickets, readDevicePrint, rememberPrinted } from "@/lib/device-print";
import { markPrinted, setTicketStatus } from "./actions";

export type Ticket = {
  id: string;
  number: string;
  status: "new" | "preparing" | "ready";
  createdAt: string;
  where: string;
  station: string;
  printedAt: string | null;
  bill: string;
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
  const [myStations, setMyStations] = useState<string[]>([]);
  const [filter, setFilter] = useState<string>("All");
  const [printing, setPrinting] = useState<Ticket[]>([]);
  const busyPrinting = useRef(false);

  useEffect(() => {
    const d = readDevicePrint();
    setMyStations(d.stations);
    if (d.stations.length === 1) setFilter(d.stations[0]);
  }, []);

  useEffect(() => {
    const t = setInterval(() => {
      setNow(Date.now());
      router.refresh();
    }, 10000);
    return () => clearInterval(t);
  }, [router]);

  // This device prints new tickets for its stations (Settings → Printers).
  useEffect(() => {
    if (myStations.length === 0 || busyPrinting.current) return;
    const done = printedTickets();
    const fresh = tickets.filter(
      (t) =>
        t.status === "new" &&
        myStations.includes(t.station) &&
        !t.printedAt &&
        !done.has(t.id) &&
        Date.now() - new Date(t.createdAt).getTime() < 30 * 60000,
    );
    if (fresh.length) setPrinting(fresh);
  }, [tickets, myStations]);

  useEffect(() => {
    if (printing.length === 0) return;
    busyPrinting.current = true;
    const ids = printing.map((t) => t.id);
    const timer = setTimeout(() => {
      window.print();
      rememberPrinted(ids);
      markPrinted(ids).finally(() => {
        busyPrinting.current = false;
        setPrinting([]);
      });
    }, 150);
    return () => clearTimeout(timer);
  }, [printing]);

  const stations = useMemo(() => [...new Set([...tickets.map((t) => t.station), ...myStations])].sort(), [tickets, myStations]);
  const shown = filter === "All" ? tickets : tickets.filter((t) => t.station === filter);

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
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #kot-print, #kot-print * { visibility: visible !important; }
          #kot-print { position: absolute !important; left: 0 !important; top: 0 !important; width: 80mm; }
          .kot-page { page-break-after: always; }
        }
      `}</style>
      <div id="kot-print" aria-hidden="true" className="pointer-events-none fixed left-[-9999px] top-0" style={{ width: "80mm", color: "#000", background: "#fff" }}>
        {printing.map((t) => (
          <div key={t.id} className="kot-page p-2 font-mono">
            <div className="text-center text-[18px] font-bold">KOT · {t.station}</div>
            <div className="flex justify-between text-[14px] font-bold">
              <span>{t.where}</span>
              <span>{new Date(t.createdAt).toLocaleTimeString("en-IN", { timeZone: timezone, hour: "2-digit", minute: "2-digit" })}</span>
            </div>
            <div className="text-[12px]">
              {t.number} · Bill {t.bill}
            </div>
            <div className="my-1 border-t border-dashed border-black" />
            {t.items.map((i, idx) => (
              <div key={idx} className="text-[16px] leading-tight" style={i.cancelled ? { textDecoration: "line-through" } : undefined}>
                <b>{i.qty} ×</b> {i.name}
                {i.cancelled && " — CANCELLED"}
                {i.note && <div className="pl-5 text-[14px] font-bold">** {i.note}</div>}
              </div>
            ))}
            <div className="my-1 border-t border-dashed border-black" />
          </div>
        ))}
      </div>
      {stations.length > 1 && (
        <div className="mb-3 flex flex-wrap gap-1.5">
          {["All", ...stations].map((s) => (
            <button
              key={s}
              onClick={() => setFilter(s)}
              className="rounded-full border px-3 py-1.5 text-xs font-semibold"
              style={{
                borderColor: filter === s ? "var(--color-brand)" : "var(--color-line)",
                background: filter === s ? "var(--color-brand)" : "transparent",
                color: filter === s ? "#fff" : "var(--color-ink-2)",
              }}
            >
              {s}
              {s !== "All" && ` (${tickets.filter((t) => t.station === s).length})`}
            </button>
          ))}
        </div>
      )}
      {myStations.length > 0 && (
        <p className="mb-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
          This device prints new tickets for: {myStations.join(", ")}.
        </p>
      )}
      {error && (
        <p className="mb-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      <div className="grid gap-4 md:grid-cols-3">
        {COLUMNS.map((col) => {
          const list = shown.filter((t) => t.status === col.key);
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
                      <div className="mb-1 flex items-center justify-between text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                        <span>
                          {t.number} · {t.station}
                        </span>
                        <button className="font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => setPrinting([t])} aria-label={`Print ticket ${t.number}`}>
                          Print
                        </button>
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
