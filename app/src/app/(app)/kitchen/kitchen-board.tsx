"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { printedTickets, readDevicePrint, rememberPrinted } from "@/lib/device-print";
import { kotLines, sendToRawbt } from "@/lib/rawbt";
import { timeOnly } from "@/lib/format";
import { claimForPrint, markKotSeen, markPrinted, setTicketStatus } from "./actions";
import { playNewTicketSound, readSoundWanted, saveSoundWanted, soundReady, soundSupported, unlockSound, watchSound } from "./sound";
import { DishName, Dual } from "../lang";

export type Ticket = {
  id: string;
  number: string;
  status: "new" | "preparing" | "ready" | "cancelled";
  createdAt: string;
  /** "Table 4", "Takeaway · Ravi", "Delivery" … */
  where: string;
  /** Token number the counter calls out, when the bill has one. */
  token: number | null;
  station: string;
  printedAt: string | null;
  bill: string;
  items: { name: string; local?: string | null; qty: number; note: string | null; cancelled: boolean; changeText?: string | null }[];
  /** A waiter changed this ticket (quantity or note) and the kitchen has not tapped "Seen" yet. */
  changed?: boolean;
  /** Why the waiter cancelled the whole ticket (status "cancelled"). */
  cancelReason?: string | null;
};

/** A ticket already marked "Served" a short while ago; it can be brought back to "Ready to serve". */
export type ServedTicket = Omit<Ticket, "status"> & { readyAt: string | null };

const COLUMNS: { key: "new" | "preparing" | "ready"; title: string; next: "preparing" | "ready" | "served"; action: string }[] = [
  { key: "new", title: "New", next: "preparing", action: "Start" },
  { key: "preparing", title: "Preparing", next: "ready", action: "Ready" },
  { key: "ready", title: "Ready to serve", next: "served", action: "Served" },
];

function minutesAgo(iso: string, now: number) {
  return Math.max(0, Math.floor((now - new Date(iso).getTime()) / 60000));
}

export function KitchenBoard({
  tickets,
  served,
  timezone,
  printMm,
  largePrint,
}: {
  tickets: Ticket[];
  /** Served in the last 2 hours, most recent first. */
  served: ServedTicket[];
  timezone: string;
  /** Paper roll width for the printed ticket, in millimetres (Settings → Bill layout). */
  printMm: number;
  /** Print the dishes in larger text (Settings → Bill layout → kitchen ticket text). */
  largePrint: boolean;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const [myStations, setMyStations] = useState<string[]>([]);
  /** This device prints through the RawBT app: new tickets wait for one tap (Android opens apps only after a tap). */
  const [rawbt, setRawbt] = useState(false);
  const [toPrint, setToPrint] = useState<Ticket[]>([]);
  const [filter, setFilter] = useState<string>("All");
  const [printing, setPrinting] = useState<Ticket[]>([]);
  const busyPrinting = useRef(false);
  const [showServed, setShowServed] = useState(false);
  // Sound for a new ticket: chosen on this device, and only "live" once the browser allows it (after a tap).
  const [soundWanted, setSoundWanted] = useState(false);
  const [soundLive, setSoundLive] = useState(false);
  const [soundMissing, setSoundMissing] = useState(false);
  /** Tickets in "New" at the last refresh (every station). Null until the first load has been seen. */
  const seenNew = useRef<Set<string> | null>(null);
  const soundButton = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const d = readDevicePrint();
    setMyStations(d.stations);
    setRawbt(d.method === "rawbt");
    if (d.stations.length === 1) setFilter(d.stations[0]);
  }, []);

  useEffect(() => {
    setSoundWanted(readSoundWanted());
    setSoundMissing(!soundSupported());
    setSoundLive(soundReady());
    return watchSound(() => setSoundLive(soundReady()));
  }, []);

  // Sound was chosen on this device earlier, but the page has been reloaded since:
  // the browser needs one tap before it plays anything, so the next tap anywhere
  // on the screen switches it back on.
  useEffect(() => {
    if (!soundWanted || soundLive) return;
    const unlock = (e: Event) => {
      // A tap on the sound button is handled by the button itself. Unlocking here as well
      // could show "Sound on" between the finger lifting and the click, and the click
      // would then switch the sound off again.
      if (e.target instanceof Node && soundButton.current?.contains(e.target)) return;
      unlockSound();
    };
    const events = ["click", "touchend", "keydown"] as const;
    events.forEach((e) => window.addEventListener(e, unlock));
    return () => events.forEach((e) => window.removeEventListener(e, unlock));
  }, [soundWanted, soundLive]);

  useEffect(() => {
    const t = setInterval(() => {
      setNow(Date.now());
      router.refresh();
    }, 10000);
    return () => clearInterval(t);
  }, [router]);

  // Beep when a ticket lands in "New" that was not there at the last refresh.
  // Tickets already on screen when the page opens never beep; with a station
  // chosen, only that station's tickets do.
  useEffect(() => {
    const fresh = tickets.filter((t) => t.status === "new");
    const before = seenNew.current;
    seenNew.current = new Set(fresh.map((t) => t.id));
    if (!before || !soundWanted) return;
    if (fresh.some((t) => !before.has(t.id) && (filter === "All" || t.station === filter))) playNewTicketSound();
  }, [tickets, filter, soundWanted]);

  // Beep when a ticket is cancelled or changed by a waiter (not for ones already on screen when the page opened).
  const seenAttention = useRef<Set<string> | null>(null);
  useEffect(() => {
    const keys = tickets.filter((t) => t.status === "cancelled" || t.changed).map((t) => `${t.id}:${t.status}:${t.changed ? "c" : ""}`);
    const before = seenAttention.current;
    seenAttention.current = new Set(keys);
    if (!before || !soundWanted) return;
    if (keys.some((k) => !before.has(k))) playNewTicketSound();
  }, [tickets, soundWanted]);

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
    if (rawbt) {
      setToPrint(fresh);
      return;
    }
    if (fresh.length === 0) return;
    // Claim them first, so a counter printing the same KOT at that moment does not print it too.
    busyPrinting.current = true;
    claimForPrint(fresh.map((t) => t.id))
      .then((claimed) => {
        const mine = claimed === null ? fresh : fresh.filter((t) => claimed.includes(t.id));
        if (mine.length) setPrinting(mine);
        else busyPrinting.current = false;
      })
      .catch(() => setPrinting(fresh));
  }, [tickets, myStations, rawbt]);

  /** RawBT: the cook taps once; the tickets are claimed (so no other device prints them) and printed. */
  function printWaiting() {
    const list = toPrint;
    if (list.length === 0) return;
    busyPrinting.current = true;
    claimForPrint(list.map((t) => t.id))
      .then((claimed) => (claimed === null ? list : list.filter((t) => claimed.includes(t.id))))
      .catch(() => list)
      .then((mine) => {
        if (mine.length) {
          const { lines, width } = kotLines(mine, { paper: printMm === 58 ? "58" : "80", timezone, large: largePrint });
          sendToRawbt(lines, width);
          rememberPrinted(mine.map((t) => t.id));
        }
        setToPrint([]);
        busyPrinting.current = false;
        router.refresh();
      });
  }

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

  const stations = useMemo(
    () => [...new Set([...tickets.map((t) => t.station), ...served.map((t) => t.station), ...myStations])].sort(),
    [tickets, served, myStations],
  );
  const shown = filter === "All" ? tickets : tickets.filter((t) => t.station === filter);
  const cancelledShown = shown.filter((t) => t.status === "cancelled");
  const servedShown = filter === "All" ? served : served.filter((t) => t.station === filter);
  const soundOn = soundWanted && soundLive;
  // Printed ticket: dishes about 25% larger when the owner chose large kitchen-ticket text.
  const itemPx = largePrint ? 20 : 16;
  const subPx = largePrint ? 18 : 14;

  function seen(id: string) {
    setBusyId(id);
    setError(null);
    start(async () => {
      const res = await markKotSeen(id);
      if (!res.ok) setError(res.error ?? "Could not save that.");
      setBusyId(null);
      router.refresh();
    });
  }

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

  /** Runs inside the tap, which is the only moment a browser lets a page switch sound on. */
  function toggleSound() {
    if (soundOn) {
      saveSoundWanted(false);
      setSoundWanted(false);
      return;
    }
    if (!unlockSound()) {
      setSoundMissing(true);
      return;
    }
    saveSoundWanted(true);
    setSoundWanted(true);
    // Play it once now, so the cook hears what a new ticket sounds like and can set the volume.
    playNewTicketSound();
  }

  return (
    <>
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #kot-print, #kot-print * { visibility: visible !important; }
          #kot-print { position: absolute !important; left: 0 !important; top: 0 !important; width: ${printMm}mm; }
          .kot-page { page-break-after: always; }
        }
      `}</style>
      <div id="kot-print" aria-hidden="true" className="pointer-events-none fixed left-[-9999px] top-0" style={{ width: `${printMm}mm`, color: "#000", background: "#fff" }}>
        {printing.map((t) => (
          <div key={t.id} className="kot-page p-2 font-mono">
            <div className="text-center text-[18px] font-bold">{t.status === "cancelled" ? "CANCELLED KOT" : t.changed ? "CHANGED KOT" : "KOT"} · {t.station}</div>
            {t.status === "cancelled" && t.cancelReason && <div className="text-center text-[13px] font-bold">Do not make. {t.cancelReason}</div>}
            {t.token != null && <div className="text-center text-[28px] font-bold leading-tight">Token {t.token}</div>}
            <div className="flex justify-between gap-2 text-[14px] font-bold">
              <span>{t.where}</span>
              <span className="shrink-0">{new Date(t.createdAt).toLocaleTimeString("en-IN", { timeZone: timezone, hour: "2-digit", minute: "2-digit" })}</span>
            </div>
            <div className="text-[12px]">
              {t.number} · Bill {t.bill}
            </div>
            <div className="my-1 border-t border-dashed border-black" />
            {t.items.map((i, idx) => (
              <div key={idx} className="leading-tight" style={{ fontSize: itemPx, textDecoration: i.cancelled ? "line-through" : undefined }}>
                <b>{i.qty} ×</b> {i.name}
                {i.local && (
                  <span className="block pl-5" style={{ fontSize: subPx }}>
                    {i.local}
                  </span>
                )}
                {i.cancelled && " — CANCELLED"}
                {i.changeText && !i.cancelled && <div className="pl-5 font-bold" style={{ fontSize: subPx }}>** {i.changeText}</div>}
                {i.note && (
                  <div className="pl-5 font-bold" style={{ fontSize: subPx }}>
                    ** {i.note}
                  </div>
                )}
              </div>
            ))}
            <div className="my-1 border-t border-dashed border-black" />
          </div>
        ))}
      </div>
      {rawbt && toPrint.length > 0 && (
        <button className="btn btn-primary mb-3 w-full text-base" onClick={printWaiting}>
          Print {toPrint.length} new {toPrint.length === 1 ? "ticket" : "tickets"}
        </button>
      )}
      <div className="mb-3 flex flex-wrap items-center gap-1.5">
        {stations.length > 1 &&
          ["All", ...stations].map((s) => (
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
        {soundMissing ? (
          <span className="ml-auto text-xs" style={{ color: "var(--color-ink-3)" }}>
            This browser cannot play a sound for new tickets.
          </span>
        ) : (
          <button
            ref={soundButton}
            type="button"
            onClick={toggleSound}
            aria-pressed={soundOn}
            className="ml-auto min-h-11 rounded-full border px-4 text-sm font-bold"
            style={
              soundOn
                ? { borderColor: "var(--color-ok)", background: "var(--color-ok-soft)", color: "var(--color-ok)" }
                : { borderColor: "var(--color-warn)", background: "var(--color-warn-soft)", color: "var(--color-warn)" }
            }
          >
            {soundOn ? "Sound on" : "Sound is off — tap to turn on"}
          </button>
        )}
      </div>
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
      {cancelledShown.length > 0 && (
        <section className="mb-4 space-y-2" aria-label="Cancelled tickets">
          {cancelledShown.map((t) => (
            <div key={t.id} role="alert" className="rounded-xl border-2 p-3" style={{ borderColor: "var(--color-bad)", background: "var(--color-bad-soft)" }}>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <div className="min-w-0">
                  <div className="text-sm font-extrabold" style={{ color: "var(--color-bad)" }}>
                    CANCELLED — do not make · {t.where || t.number}
                  </div>
                  <div className="text-[11px]" style={{ color: "var(--color-ink-2)" }}>
                    {t.number} · {t.station}
                    {t.cancelReason ? ` · ${t.cancelReason}` : ""}
                  </div>
                </div>
                <div className="flex shrink-0 gap-2">
                  <button className="btn border text-sm" style={{ borderColor: "var(--color-bad)", background: "var(--color-surface)", color: "var(--color-bad)" }} onClick={() => setPrinting([t])}>
                    Print
                  </button>
                  <button className="btn btn-primary text-sm" disabled={pending && busyId === t.id} onClick={() => seen(t.id)}>
                    {pending && busyId === t.id ? "…" : "Seen"}
                  </button>
                </div>
              </div>
              <ul className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
                {t.items.map((i, idx) => (
                  <li key={idx} style={{ textDecoration: "line-through" }}>
                    {i.qty}× <DishName name={i.name} local={i.local} />
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </section>
      )}
      <div className="grid gap-4 md:grid-cols-3">
        {COLUMNS.map((col) => {
          const list = shown.filter((t) => t.status === col.key);
          return (
            <section key={col.key}>
              <h2 className="mb-2 text-sm font-bold">
                <Dual text={col.title} /> <span style={{ color: "var(--color-ink-3)" }}>({list.length})</span>
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
                    <div key={t.id} className="card p-3" style={t.changed ? { borderColor: "var(--color-warn)", borderWidth: 2 } : late ? { borderColor: "var(--color-bad)" } : undefined}>
                      {t.changed && (
                        <div className="-mx-1 -mt-1 mb-2 flex items-center justify-between gap-2 rounded-lg px-2 py-1.5" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }} role="alert">
                          <span className="text-xs font-extrabold">CHANGED by the waiter</span>
                          <button className="rounded-md border px-2.5 py-1 text-xs font-bold" style={{ borderColor: "var(--color-warn)", background: "var(--color-surface)" }} disabled={pending && busyId === t.id} onClick={() => seen(t.id)}>
                            Seen
                          </button>
                        </div>
                      )}
                      <div className="mb-2 flex items-start justify-between gap-2">
                        <div className="min-w-0">
                          {t.token != null && <div className="font-display text-2xl font-bold leading-tight">Token {t.token}</div>}
                          {(t.where || t.token == null) && <div className="break-words text-sm font-bold">{t.where || t.number}</div>}
                        </div>
                        <span className="shrink-0 text-xs tabular-nums" style={{ color: late ? "var(--color-bad)" : "var(--color-ink-3)" }}>
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
                            <span className="font-bold tabular-nums">{i.qty}×</span> <DishName name={i.name} local={i.local} />
                            {i.cancelled && <span className="ml-1 text-[11px] font-bold no-underline">CANCELLED</span>}
                            {i.changeText && !i.cancelled && (
                              <div className="text-xs font-bold" style={{ color: "var(--color-warn)" }}>
                                {i.changeText}
                              </div>
                            )}
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
                        {pending && busyId === t.id ? "…" : <Dual text={col.action} />}
                      </button>
                    </div>
                  );
                })}
              </div>
            </section>
          );
        })}
      </div>
      {servedShown.length > 0 && (
        <section className="mt-6">
          <button
            type="button"
            onClick={() => setShowServed((v) => !v)}
            aria-expanded={showServed}
            className="tap flex w-full items-center justify-between gap-3 rounded-xl border px-4 text-left text-sm font-bold"
            style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}
          >
            <span>Served in the last 2 hours ({servedShown.length})</span>
            <span className="shrink-0 text-xs font-semibold" style={{ color: "var(--color-brand)" }}>
              {showServed ? "Hide" : "Show"}
            </span>
          </button>
          {showServed && (
            <ul className="card mt-2 overflow-hidden">
              {servedShown.map((t) => {
                const dishes = t.items.filter((i) => !i.cancelled);
                const busy = pending && busyId === t.id;
                return (
                  <li
                    key={t.id}
                    className="flex flex-wrap items-center gap-x-3 gap-y-2 border-b px-3 py-2 last:border-b-0"
                    style={{ borderColor: "var(--color-line)" }}
                  >
                    <div className="min-w-0 flex-1 basis-56">
                      <div className="break-words text-sm font-bold">
                        {[t.token != null ? `Token ${t.token}` : "", t.where].filter(Boolean).join(" · ") || t.number}
                      </div>
                      <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                        {t.number} · {t.station}
                        {t.readyAt && ` · Ready ${timeOnly(t.readyAt, timezone)}`}
                      </div>
                      <div className="break-words text-xs" style={{ color: "var(--color-ink-2)" }}>
                        {dishes.length ? dishes.map((i) => `${i.qty}× ${i.name}`).join(", ") : "No dishes"}
                      </div>
                    </div>
                    <button
                      type="button"
                      className="btn shrink-0 border text-sm"
                      style={{ borderColor: "var(--color-brand)", background: "var(--color-surface)", color: "var(--color-brand)" }}
                      disabled={busy}
                      onClick={() => move(t.id, "ready")}
                    >
                      {busy ? "…" : "Bring back"}
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </section>
      )}
    </>
  );
}
