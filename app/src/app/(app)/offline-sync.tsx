"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { readQueue, readStuck, writeQueue, writeStuck, type OfflineBill } from "@/lib/offline";
import { applySyncOutcome, retryStuck } from "@/lib/offline-queue";
import { flushPrintQueue, PRINT_QUEUE_CHANGED, readPrintQueue, retryApproved, summarize, toSendResult, type PrintEvent, type SendResult } from "@/lib/print-log";
import { syncOfflineBill } from "./pos/actions";
import { logPrint } from "./bills/log-print";
import { ApprovalPrompt } from "./approval";

/** How many times a bill's guest details are tried before they are given up. */
const GUEST_TRIES = 5;

/** One queued print (offline receipt, Ctrl+P, a failed log call) -> the logPrint action. Throws when the server cannot be reached. */
async function sendPrint(ev: PrintEvent): Promise<SendResult> {
  return toSendResult(await logPrint({ kind: ev.kind, orderId: ev.orderId, clientRef: ev.billClientRef, ticketIds: ev.ticketIds, isReprint: ev.isReprint }));
}

/** Sends bills made offline on this device as soon as the server can be reached, and shows what is waiting. */
export function OfflineSync() {
  const [queue, setQueue] = useState<OfflineBill[]>([]);
  const [stuck, setStuck] = useState<OfflineBill[]>([]);
  const [online, setOnline] = useState(true);
  const [note, setNote] = useState<string | null>(null);
  const busy = useRef(false);
  const printBusy = useRef(false);
  const [prints, setPrints] = useState({ total: 0, needsApproval: 0, gaveUp: 0 });
  const [pinOpen, setPinOpen] = useState(false);

  /**
   * Records queued prints (reprint audit). Runs after the bills, so an offline bill's print finds its bill on the server; a print whose
   * bill is not there yet just waits. Prints are sent in order per bill, each once (client ref), and a print that needs a manager PIN
   * waits for a person (banner below) instead of being retried.
   */
  const runPrints = useCallback(async () => {
    setPrints(summarize(readPrintQueue()));
    if (printBusy.current || !navigator.onLine || readPrintQueue().length === 0) return;
    printBusy.current = true;
    try {
      await flushPrintQueue(sendPrint);
    } finally {
      printBusy.current = false;
      setPrints(summarize(readPrintQueue()));
    }
  }, []);

  const approvedPrint = async () => {
    setPinOpen(false);
    const first = readPrintQueue().find((e) => e.needs_approval && !e.gave_up);
    if (!first) return;
    try {
      await retryApproved(first.ref, sendPrint);
    } catch {
      /* no connection: it stays queued */
    }
    setPrints(summarize(readPrintQueue()));
    void runPrints();
  };

  const runBills = useCallback(async () => {
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

  const run = useCallback(async () => {
    await runBills();
    await runPrints();
  }, [runBills, runPrints]);

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
    // A print was queued (or the queue changed): update the banner and record it. Writes made by a running flush are ignored (printBusy).
    const printsChanged = () => void runPrints();
    window.addEventListener(PRINT_QUEUE_CHANGED, printsChanged);
    const t = setInterval(run, 20000);
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
      window.removeEventListener("sna-offline-queue", changed);
      window.removeEventListener(PRINT_QUEUE_CHANGED, printsChanged);
      clearInterval(t);
    };
  }, [run, runPrints]);

  const printNeedsPin = prints.needsApproval > 0 || prints.gaveUp > 0;
  if (online && queue.length === 0 && !note && stuck.length === 0 && !printNeedsPin) return null;
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
    {printNeedsPin && (
      <div className="no-print mb-3 flex flex-wrap items-center justify-between gap-2 rounded-xl px-3 py-2 text-sm" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-ink)" }}>
        <span>
          {prints.needsApproval > 0 && `${prints.needsApproval} reprint${prints.needsApproval === 1 ? "" : "s"} made without the reprint right ${prints.needsApproval === 1 ? "is" : "are"} not recorded yet: a manager PIN records ${prints.needsApproval === 1 ? "it" : "one at a time"}. `}
          {prints.gaveUp > 0 && `${prints.gaveUp} print record${prints.gaveUp === 1 ? "" : "s"} could not be saved to the log and stay${prints.gaveUp === 1 ? "s" : ""} on this device.`}
        </span>
        {prints.needsApproval > 0 && online && (
          <button className="rounded-lg border px-3 py-1 text-xs font-bold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }} onClick={() => setPinOpen(true)}>
            Enter manager PIN
          </button>
        )}
      </div>
    )}
    {pinOpen && <ApprovalPrompt permission="order.reprint" onCancel={() => setPinOpen(false)} onApproved={() => void approvedPrint()} />}
    {!(printNeedsPin && online && queue.length === 0 && !note && stuck.length === 0) && (
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
    )}
    </>
  );
}
