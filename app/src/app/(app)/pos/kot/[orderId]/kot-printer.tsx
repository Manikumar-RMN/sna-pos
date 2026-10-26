"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { readDevicePrint, rememberPrinted } from "@/lib/device-print";
import { ApprovalPrompt, cleanMessage, neededRight } from "../../../approval";
import { logPrint } from "../../../bills/log-print";
import { dropPrint, recordDeclaredPrint, useBrowserPrint } from "@/lib/print-log";
import { claimTickets, loadKot } from "./actions";
import { KotTicketsPrint, runPrint, type KotSlip } from "./kot-print";

export type { KotSlip } from "./kot-print";

/** Seconds before the screen moves on by itself, once printing is over. */
const MOVE_ON_AFTER = 3;

/**
 * KOT pressed: the order's new items go to the kitchen and their ticket prints here, then the
 * screen goes on to the next order (or back to the bill). The ticket looks the same as the one the
 * Kitchen screen prints. Tickets are claimed before printing, so the Kitchen screen of another
 * device does not print them as well.
 *
 * `embedded` is the single order screen (pos/order-desk.tsx): the same work happens in an overlay on top of that screen and,
 * instead of moving to another page, `onDone` is called when printing is over. "Print KOT again" is a reprint: it is logged
 * (log_print, migration 135) and needs the reprint right or a manager PIN. The first print after KOT is never logged.
 */
export function KotPrinter({
  orderId,
  billNumber,
  where,
  token,
  backToBill,
  timezone,
  printMm,
  largePrint,
  embedded = false,
  onDone,
}: {
  orderId: string;
  billNumber: string;
  where: string;
  token: number | null;
  backToBill: boolean;
  timezone: string;
  printMm: number;
  largePrint: boolean;
  embedded?: boolean;
  onDone?: () => void;
}) {
  const router = useRouter();
  const [slips, setSlips] = useState<KotSlip[] | null>(null);
  const [printing, setPrinting] = useState<KotSlip[]>([]);
  const [printedHere, setPrintedHere] = useState<KotSlip[]>([]);
  const [status, setStatus] = useState<"loading" | "printing" | "done">("loading");
  const [deviceOff, setDeviceOff] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [printError, setPrintError] = useState<string | null>(null);
  const [needsPin, setNeedsPin] = useState(false);
  const [declaredNote, setDeclaredNote] = useState<{ text: string; ref?: string; needsPin?: boolean } | null>(null);
  const [pinForDeclared, setPinForDeclared] = useState<string | null>(null);
  const [countdown, setCountdown] = useState<number | null>(null);
  const [attempt, setAttempt] = useState(0);
  const started = useRef(false);
  const next = backToBill ? `/bills/${orderId}` : "/pos";
  const info = { billNumber, where, token, timezone, printMm, largePrint };

  /** Leaves this screen: back to the order screen (embedded) or on to the next page. */
  function finish() {
    if (embedded) onDone?.();
    else router.replace(next);
  }

  // Once: send to the kitchen, then claim and print this round's tickets if this device prints KOTs.
  useEffect(() => {
    if (started.current) return;
    started.current = true;
    (async () => {
      let res: Awaited<ReturnType<typeof loadKot>>;
      try {
        res = await loadKot(orderId);
      } catch {
        setError("The internet dropped. The bill is saved; press “Send to kitchen again” when the connection is back.");
        setStatus("done");
        return;
      }
      if (!res.ok) {
        setError(res.error);
        setStatus("done");
        return;
      }
      setSlips(res.slips);
      const dev = readDevicePrint();
      if (!dev.kotHere) {
        setDeviceOff(true);
        setStatus("done");
        setCountdown(MOVE_ON_AFTER);
        return;
      }
      const fresh = res.slips.filter((s) => !s.printed);
      const claimed = new Set(await claimTickets(fresh.map((s) => s.id)).catch(() => [] as string[]));
      const mine = fresh.filter((s) => claimed.has(s.id));
      if (mine.length === 0) {
        setStatus("done");
        setCountdown(MOVE_ON_AFTER);
        return;
      }
      setPrinting(mine);
      setStatus("printing");
    })();
  }, [orderId, attempt]);

  // The tickets are on the page: print them, wait for the print window to close, then move on.
  useEffect(() => {
    if (printing.length === 0) return;
    let alive = true;
    const t = window.setTimeout(async () => {
      await runPrint(printing, info);
      if (!alive) return;
      rememberPrinted(printing.map((s) => s.id));
      setPrintedHere(printing);
      setPrinting([]);
      setStatus("done");
      setCountdown(MOVE_ON_AFTER);
    }, 60);
    return () => {
      alive = false;
      window.clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [printing]);

  useEffect(() => {
    if (countdown === null) return;
    if (countdown <= 0) {
      finish();
      return;
    }
    const t = window.setTimeout(() => setCountdown((c) => (c === null ? null : c - 1)), 1000);
    return () => window.clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [countdown, next, router]);

  /** Print again = a reprint: logged first; a role without the right gets the manager PIN prompt. Prints only when the log is written. */
  async function printAgain() {
    setCountdown(null);
    setPrintError(null);
    const again = printedHere.length > 0 ? printedHere : (slips ?? []);
    if (again.length === 0) return;
    let res: Awaited<ReturnType<typeof logPrint>>;
    try {
      res = await logPrint({ kind: "kot", orderId, ticketIds: again.map((s) => s.id) });
    } catch {
      return setPrintError("Could not record the reprint. Check the internet and try again.");
    }
    if (!res.ok) {
      if (neededRight(res.error) === "order.reprint") return setNeedsPin(true);
      return setPrintError(cleanMessage(res.error));
    }
    setPrinting(again);
  }

  /**
   * Ctrl+P or the browser menu on this screen: the tickets of this bill are a copy, so it is recorded as a KOT reprint (the page cannot
   * stop it). Needs the reprint right; without it a notice offers the manager PIN and the print waits in the device queue.
   */
  async function logDeclaredKot() {
    const ids = (printedHere.length > 0 ? printedHere : (slips ?? [])).map((s) => s.id);
    if (ids.length === 0) return;
    setCountdown(null);
    const out = await recordDeclaredPrint({ kind: "kot", orderId, ticketIds: ids, isReprint: true }, (e) => logPrint({ kind: "kot", orderId: e.orderId, ticketIds: e.ticketIds }));
    if (out.status === "recorded") return setDeclaredNote({ text: "Printed from the browser menu: recorded as a KOT reprint." });
    if (out.status === "offline") return setDeclaredNote({ text: "Printed from the browser menu. The record is saved on this device and is sent when the internet is back." });
    if (out.status === "needs_approval")
      return setDeclaredNote({ text: "Printed from the browser menu, not recorded yet: a reprint needs the reprint right or a manager PIN.", ref: out.ref, needsPin: true });
    setDeclaredNote({ text: `Printed from the browser menu, not recorded yet: ${cleanMessage(out.error)}` });
  }
  useBrowserPrint(status === "done" && !error && (slips?.length ?? 0) > 0, () => void logDeclaredKot());

  async function recordDeclaredWithPin(ref: string) {
    const ids = (printedHere.length > 0 ? printedHere : (slips ?? [])).map((s) => s.id);
    try {
      const res = await logPrint({ kind: "kot", orderId, ticketIds: ids });
      if (res.ok) {
        dropPrint(ref);
        return setDeclaredNote({ text: "Browser-menu print recorded as a KOT reprint." });
      }
      setDeclaredNote({ text: `Not recorded: ${cleanMessage(res.error)}`, ref, needsPin: neededRight(res.error) === "order.reprint" });
    } catch {
      setDeclaredNote({ text: "Not recorded: could not reach the server. It stays queued on this device.", ref });
    }
  }

  function retry() {
    if (embedded) {
      // Stay on the order screen: ask the server again (nothing is sent twice).
      started.current = false;
      setError(null);
      setStatus("loading");
      setAttempt((a) => a + 1);
      return;
    }
    // Start this page again: it sends to the kitchen once more (nothing is sent twice).
    window.location.reload();
  }

  const list = slips ?? [];
  const dishes = list.reduce((n, s) => n + s.items.filter((i) => !i.cancelled).reduce((a, i) => a + i.qty, 0), 0);

  const card = (
    <div className="card p-6 text-center" style={embedded ? { background: "var(--color-surface)" } : undefined} role={embedded ? "dialog" : undefined} aria-label={embedded ? "Sending to the kitchen" : undefined}>
      <div className="text-xs font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
        KOT
      </div>
      <h1 className="mt-1 text-2xl font-bold">
        {status === "loading" ? "Sending to the kitchen…" : error ? "Saved, not sent yet" : list.length > 0 ? "Sent to the kitchen" : "Saved"}
      </h1>
      <p className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
        {where ? `${where} · ` : ""}Bill {billNumber}
        {token != null ? ` · Token ${token}` : ""}
      </p>

      {error && (
        <p className="mt-3 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      {printError && (
        <p className="mt-3 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {printError}
        </p>
      )}
      {declaredNote && (
        <p className="no-print mt-3 flex flex-wrap items-center justify-between gap-2 rounded-lg px-3 py-2 text-left text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-ink)" }}>
          <span>{declaredNote.text}</span>
          <span className="flex gap-2">
            {declaredNote.needsPin && declaredNote.ref && (
              <button className="rounded-lg border px-2.5 py-1 font-bold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }} onClick={() => setPinForDeclared(declaredNote.ref ?? null)}>
                Record with manager PIN
              </button>
            )}
            <button className="font-semibold underline" onClick={() => setDeclaredNote(null)}>
              Dismiss
            </button>
          </span>
        </p>
      )}
      {!error && status !== "loading" && list.length === 0 && (
        <p className="mt-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
          Nothing new went to the kitchen: the items are held for a later course. Send them from the bill when it is time.
        </p>
      )}
      {!error && list.length > 0 && (
        <p className="mt-3 text-sm" style={{ color: "var(--color-ink-3)" }}>
          {dishes} {dishes === 1 ? "item" : "items"} on {list.length} {list.length === 1 ? "ticket" : "tickets"}.{" "}
          {status === "printing"
            ? "Printing the KOT…"
            : deviceOff
              ? "This device is set not to print KOTs (Settings → Printers); the kitchen prints them."
              : printedHere.length > 0
                ? "KOT printed here."
                : "The KOT was already printed by another printer."}
        </p>
      )}
      <p className="mt-3 text-sm" style={{ color: "var(--color-ink-3)" }}>
        The bill stays open. Print it and take the payment from {embedded || backToBill ? "the bill" : "Bills or the table"} when the guest is ready.
      </p>

      <div className="mt-5 grid gap-2">
        {error ? (
          <button className="btn btn-primary text-base" onClick={retry}>
            Send to kitchen again
          </button>
        ) : (
          <button className="btn btn-primary text-base" disabled={status !== "done"} onClick={finish}>
            {embedded ? "Done" : backToBill ? "Back to the bill" : "Next order"}
            {countdown !== null && countdown > 0 ? ` (${countdown})` : ""}
          </button>
        )}
        <div className={embedded ? "grid gap-2" : "grid grid-cols-2 gap-2"}>
          {embedded ? (
            error && (
              <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={finish}>
                Open the bill
              </button>
            )
          ) : (
            <Link href={`/bills/${orderId}`} className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setCountdown(null)}>
              {backToBill ? "Back to the bill" : "Open the bill"}
            </Link>
          )}
          <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={status !== "done" || list.length === 0} onClick={printAgain}>
            Print KOT again
          </button>
        </div>
        {countdown !== null && countdown > 0 && (
          <button className="text-xs font-semibold underline" style={{ color: "var(--color-ink-3)" }} onClick={() => setCountdown(null)}>
            Stay on this page
          </button>
        )}
      </div>
    </div>
  );

  return (
    <>
      {printing.length > 0 && <KotTicketsPrint slips={printing} info={info} />}
      {pinForDeclared && (
        <ApprovalPrompt
          permission="order.reprint"
          onCancel={() => setPinForDeclared(null)}
          onApproved={() => {
            const ref = pinForDeclared;
            setPinForDeclared(null);
            void recordDeclaredWithPin(ref);
          }}
        />
      )}
      {needsPin && (
        <ApprovalPrompt
          permission="order.reprint"
          onCancel={() => setNeedsPin(false)}
          onApproved={() => {
            setNeedsPin(false);
            void printAgain();
          }}
        />
      )}
      {embedded ? (
        <div className="no-print fixed inset-0 z-40 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }}>
          <div className="w-full max-w-md">{card}</div>
        </div>
      ) : (
        <div className="mx-auto max-w-md">{card}</div>
      )}
    </>
  );
}
