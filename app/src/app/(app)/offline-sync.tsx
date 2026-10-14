"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { readQueue, readStuck, writeQueue, writeStuck, type OfflineBill } from "@/lib/offline";
import { applySyncOutcome, retryStuck } from "@/lib/offline-queue";
import { syncOfflineBill } from "./pos/actions";

/** How many times a bill's guest details are tried before they are given up. */
const GUEST_TRIES = 5;

/** Sends bills made offline on this device as soon as the server can be reached, and shows what is waiting. */
export function OfflineSync() {
  const [queue, setQueue] = useState<OfflineBill[]>([]);
  const [stuck, setStuck] = useState<OfflineBill[]>([]);
  const [online, setOnline] = useState(true);
  const [note, setNote] = useState<string | null>(null);
  const busy = useRef(false);

  const run = useCallback(async () => {
    const q = readQueue();
    setQueue(q);
    setStuck(readStuck());
    if (!q.length || busy.current || !navigator.onLine) return;
    busy.current = true;
    let problem: string | null = null;
    try {
      for (const bill of q) {
        let res: Awaited<ReturnType<typeof syncOfflineBill>>;
        try {
          // After several tries the guest details are given up, so they can never hold a bill here for ever.
          res = await syncOfflineBill(bill, { skipGuest: (bill.guest_tries ?? 0) >= GUEST_TRIES });
        } catch {
          problem = "Waiting for the internet…";
          break;
        }
        // The queue is read again every time it is written: a bill made on this device while this one was
        // being sent is in the fresh copy, and must not be wiped out by an older one.
        const out = applySyncOutcome(readQueue(), readStuck(), bill, res);
        // A bill is only taken out of the queue once its copy in the stuck list is safely stored.
        if (out.moved && !writeStuck(out.stuck)) {
          problem = `Bill ${bill.number} was refused and this device's storage is full, so it stays in the queue. Free some space.`;
          break;
        }
        writeQueue(out.queue);
        setQueue(out.queue);
        setStuck(out.stuck);
        if (res.ok) {
          if (res.guestDropped) problem = `Bill ${bill.number} was sent, but its guest details could not be saved. Add them on the bill.`;
        } else if (res.guestPending) {
          problem = res.error ?? "Waiting to send guest details…";
        } else if (res.refused) {
          // The server said no to this bill itself. It must not hold up the bills behind it: carry on.
          problem = `Bill ${bill.number} was refused: ${res.error ?? "unknown reason"}`;
        }
        if (out.stop) {
          problem = res.error ?? "A bill could not be sent.";
          break;
        }
      }
    } finally {
      const told = problem?.startsWith("Bill ") ? problem : null;
      setNote(readQueue().length || told ? problem : null);
      // With nothing left to send, the note about guest details has no later run to clear it: take it away after a minute.
      if (told) setTimeout(() => setNote((n) => (n === told ? null : n)), 60000);
      busy.current = false;
    }
  }, []);

  const retry = () => {
    const back = retryStuck(readQueue(), readStuck());
    writeQueue(back.queue);
    writeStuck(back.stuck);
    setQueue(back.queue);
    setStuck(back.stuck);
    run();
  };
  const download = () => {
    const blob = new Blob([JSON.stringify(readStuck(), null, 2)], { type: "application/json" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `sna-pos-unsent-bills-${new Date().toISOString().slice(0, 10)}.json`;
    a.click();
    URL.revokeObjectURL(a.href);
  };

  useEffect(() => {
    setOnline(navigator.onLine);
    run();
    const on = () => {
      setOnline(true);
      run();
    };
    const off = () => setOnline(false);
    const changed = () => setQueue(readQueue());
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    window.addEventListener("sna-offline-queue", changed);
    const t = setInterval(run, 20000);
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
      window.removeEventListener("sna-offline-queue", changed);
      clearInterval(t);
    };
  }, [run]);

  if (online && queue.length === 0 && !note && stuck.length === 0) return null;
  return (
    <>
    {stuck.length > 0 && (
      <div className="no-print mb-3 flex flex-wrap items-center justify-between gap-2 rounded-xl px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
        <span>
          <b>{stuck.length} offline bill{stuck.length === 1 ? "" : "s"} could not be accepted by the server</b> ({stuck.map((b) => b.number).join(", ")}). They are saved on this device, not lost. Tell the owner: {stuck[0].sync_error}
        </span>
        <span className="flex gap-2">
          <button className="rounded-lg border px-3 py-1 text-xs font-bold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }} onClick={download}>Save a copy</button>
          <button className="rounded-lg border px-3 py-1 text-xs font-bold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }} onClick={retry}>Try again</button>
        </span>
      </div>
    )}
    <div
      className="no-print mb-3 flex flex-wrap items-center justify-between gap-2 rounded-xl px-3 py-2 text-sm"
      role="status"
      style={{ background: online ? "var(--color-warn-soft)" : "var(--color-bad-soft)", color: online ? "var(--color-ink)" : "var(--color-bad)" }}
    >
      <span>
        {!online && <b>No internet. </b>}
        {!online && "Billing continues offline for paid bills. "}
        {queue.length > 0 && (
          <>
            {queue.length} offline bill{queue.length === 1 ? "" : "s"} waiting to be sent from this device.
            {note && online ? ` ${note}` : ""}
          </>
        )}
        {queue.length === 0 && note && online ? note : ""}
      </span>
      {online && queue.length > 0 && (
        <button className="rounded-lg border px-3 py-1 text-xs font-bold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }} onClick={run}>
          Send now
        </button>
      )}
    </div>
    </>
  );
}
