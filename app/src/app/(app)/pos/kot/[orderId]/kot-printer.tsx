"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { readDevicePrint, rememberPrinted } from "@/lib/device-print";
import { claimTickets, loadKot } from "./actions";

export type KotSlip = {
  id: string;
  number: string;
  station: string;
  createdAt: string;
  printed: boolean;
  items: { name: string; local: string | null; qty: number; note: string | null; cancelled: boolean }[];
};

/** Seconds before the screen moves on by itself, once printing is over. */
const MOVE_ON_AFTER = 3;

/** Opens the print window and waits until it is closed (Chrome blocks; Safari and others tell us with "afterprint"). */
function printAndWait(): Promise<void> {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      window.removeEventListener("afterprint", finish);
      resolve();
    };
    window.addEventListener("afterprint", finish);
    window.print();
    // A browser that neither blocks nor says "afterprint": do not wait for ever.
    window.setTimeout(finish, 20_000);
  });
}

/**
 * KOT pressed: the order's new items go to the kitchen and their ticket prints here, then the
 * screen goes on to the next order (or back to the bill). The ticket looks the same as the one the
 * Kitchen screen prints. Tickets are claimed before printing, so the Kitchen screen of another
 * device does not print them as well.
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
}: {
  orderId: string;
  billNumber: string;
  where: string;
  token: number | null;
  backToBill: boolean;
  timezone: string;
  printMm: number;
  largePrint: boolean;
}) {
  const router = useRouter();
  const [slips, setSlips] = useState<KotSlip[] | null>(null);
  const [printing, setPrinting] = useState<KotSlip[]>([]);
  const [printedHere, setPrintedHere] = useState<KotSlip[]>([]);
  const [status, setStatus] = useState<"loading" | "printing" | "done">("loading");
  const [deviceOff, setDeviceOff] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [countdown, setCountdown] = useState<number | null>(null);
  const started = useRef(false);
  const next = backToBill ? `/bills/${orderId}` : "/pos";

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
  }, [orderId]);

  // The tickets are on the page: print them, wait for the print window to close, then move on.
  useEffect(() => {
    if (printing.length === 0) return;
    let alive = true;
    const t = window.setTimeout(async () => {
      await printAndWait();
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
  }, [printing]);

  useEffect(() => {
    if (countdown === null) return;
    if (countdown <= 0) {
      router.replace(next);
      return;
    }
    const t = window.setTimeout(() => setCountdown((c) => (c === null ? null : c - 1)), 1000);
    return () => window.clearTimeout(t);
  }, [countdown, next, router]);

  function printAgain() {
    setCountdown(null);
    const again = printedHere.length > 0 ? printedHere : (slips ?? []);
    if (again.length > 0) setPrinting(again);
  }

  function retry() {
    // Start this page again: it sends to the kitchen once more (nothing is sent twice).
    window.location.reload();
  }

  const itemPx = largePrint ? 20 : 16;
  const subPx = largePrint ? 18 : 14;
  const list = slips ?? [];
  const dishes = list.reduce((n, s) => n + s.items.filter((i) => !i.cancelled).reduce((a, i) => a + i.qty, 0), 0);

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
            <div className="text-center text-[18px] font-bold">KOT · {t.station}</div>
            {token != null && <div className="text-center text-[28px] font-bold leading-tight">Token {token}</div>}
            <div className="flex justify-between gap-2 text-[14px] font-bold">
              <span>{where}</span>
              <span className="shrink-0">{new Date(t.createdAt).toLocaleTimeString("en-IN", { timeZone: timezone, hour: "2-digit", minute: "2-digit" })}</span>
            </div>
            <div className="text-[12px]">
              {t.number} · Bill {billNumber}
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

      <div className="mx-auto max-w-md">
        <div className="card p-6 text-center">
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
            The bill stays open. Print it and take the payment from {backToBill ? "the bill" : "Bills or the table"} when the guest is ready.
          </p>

          <div className="mt-5 grid gap-2">
            {error ? (
              <button className="btn btn-primary text-base" onClick={retry}>
                Send to kitchen again
              </button>
            ) : (
              <button className="btn btn-primary text-base" disabled={status !== "done"} onClick={() => router.replace(next)}>
                {backToBill ? "Back to the bill" : "Next order"}
                {countdown !== null && countdown > 0 ? ` (${countdown})` : ""}
              </button>
            )}
            <div className="grid grid-cols-2 gap-2">
              {!backToBill ? (
                <Link href={`/bills/${orderId}`} className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setCountdown(null)}>
                  Open the bill
                </Link>
              ) : (
                <Link href={`/bills/${orderId}`} className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setCountdown(null)}>
                  Back to the bill
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
      </div>
    </>
  );
}
