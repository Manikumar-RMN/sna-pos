"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { readDevicePrint, rememberPrinted } from "@/lib/device-print";
import { ApprovalPrompt, cleanMessage, neededRight } from "../../../approval";
import { logPrint } from "../../../bills/log-print";
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
