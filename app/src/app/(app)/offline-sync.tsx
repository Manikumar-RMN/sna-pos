"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { readQueue, writeQueue, type OfflineBill } from "@/lib/offline";
import { syncOfflineBill } from "./pos/actions";

/** Sends bills made offline on this device as soon as the server can be reached, and shows what is waiting. */
export function OfflineSync() {
  const [queue, setQueue] = useState<OfflineBill[]>([]);
  const [online, setOnline] = useState(true);
  const [note, setNote] = useState<string | null>(null);
  const busy = useRef(false);

  const run = useCallback(async () => {
    const q = readQueue();
    setQueue(q);
    if (!q.length || busy.current || !navigator.onLine) return;
    busy.current = true;
    let left = [...q];
    for (const bill of q) {
      let res: { ok: boolean; error?: string; waiting?: boolean };
      try {
        res = await syncOfflineBill(bill);
      } catch {
        setNote("Waiting for the internet…");
        break;
      }
      if (res.ok) {
        left = left.filter((b) => b.client_id !== bill.client_id);
        writeQueue(left);
        setQueue(left);
      } else {
        setNote(res.error ?? "A bill could not be sent.");
        break;
      }
    }
    if (!left.length) setNote(null);
    busy.current = false;
  }, []);

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

  if (online && queue.length === 0) return null;
  return (
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
      </span>
      {online && queue.length > 0 && (
        <button className="rounded-lg border px-3 py-1 text-xs font-bold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }} onClick={run}>
          Send now
        </button>
      )}
    </div>
  );
}
