"use client";

import { useEffect, useState } from "react";
import { readDevicePrint } from "@/lib/device-print";
import { kotLines, sendToRawbt } from "@/lib/rawbt";
import { markAppPrint } from "@/lib/print-log";

/** One kitchen ticket as it is printed. */
export type KotSlip = {
  id: string;
  number: string;
  station: string;
  createdAt: string;
  printed: boolean;
  items: { name: string; local: string | null; qty: number; note: string | null; cancelled: boolean }[];
};

/** What is printed around the items: the bill, the table, the token and how this outlet lays out a ticket. */
export type KotPrintInfo = {
  billNumber: string;
  where: string;
  token: number | null;
  timezone: string;
  printMm: number;
  largePrint: boolean;
};

/** Opens the print window and waits until it is closed (Chrome blocks; Safari and others tell us with "afterprint"). */
export function printAndWait(): Promise<void> {
  return new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (done) return;
      done = true;
      window.removeEventListener("afterprint", finish);
      resolve();
    };
    window.addEventListener("afterprint", finish);
    // The app's own print (first KOT print is not logged, a reprint was logged just before): the Ctrl+P listeners must skip it.
    markAppPrint();
    window.print();
    // A browser that neither blocks nor says "afterprint": do not wait for ever.
    window.setTimeout(finish, 20_000);
  });
}

/**
 * Prints the tickets the way this device is set up (Settings -> Printers). For the browser's print window the tickets must
 * already be on the page (<KotTicketsPrint>); RawBT gets them as text and is given a moment to take the job.
 */
export async function runPrint(slips: KotSlip[], info: KotPrintInfo): Promise<void> {
  if (readDevicePrint().method === "rawbt") {
    const { lines, width } = kotLines(
      slips.map((s) => ({ ...s, bill: info.billNumber, where: info.where, token: info.token })),
      { paper: info.printMm === 58 ? "58" : "80", timezone: info.timezone, large: info.largePrint },
    );
    sendToRawbt(lines, width);
    await new Promise((r) => window.setTimeout(r, 1500));
  } else await printAndWait();
}

/**
 * The tickets as a hidden block that only the print window shows. While it prints, a bill receipt on the same page is hidden
 * (the receipt has its own print rule that would otherwise print it together with the ticket).
 */
export function KotTicketsPrint({ slips, info }: { slips: KotSlip[]; info: KotPrintInfo }) {
  const itemPx = info.largePrint ? 20 : 16;
  const subPx = info.largePrint ? 18 : 14;
  return (
    <>
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #kot-print, #kot-print * { visibility: visible !important; }
          #kot-print { position: absolute !important; left: 0 !important; top: 0 !important; width: ${info.printMm}mm; }
          #receipt { display: none !important; }
          .kot-page { page-break-after: always; }
        }
      `}</style>
      <div id="kot-print" aria-hidden="true" className="pointer-events-none fixed left-[-9999px] top-0" style={{ width: `${info.printMm}mm`, color: "#000", background: "#fff" }}>
        {slips.map((t) => (
          <div key={t.id} className="kot-page p-2 font-mono">
            <div className="text-center text-[18px] font-bold">KOT · {t.station}</div>
            {info.token != null && <div className="text-center text-[28px] font-bold leading-tight">Token {info.token}</div>}
            <div className="flex justify-between gap-2 text-[14px] font-bold">
              <span>{info.where}</span>
              <span className="shrink-0">{new Date(t.createdAt).toLocaleTimeString("en-IN", { timeZone: info.timezone, hour: "2-digit", minute: "2-digit" })}</span>
            </div>
            <div className="text-[12px]">
              {t.number} · Bill {info.billNumber}
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
    </>
  );
}

/**
 * For screens that print a ticket on request (the "Sent KOTs" sheet): `print(slips, info)` puts the tickets on the page, prints
 * them and resolves when the print window has closed. Render `node` somewhere in the component.
 */
export function useSlipPrinter() {
  const [job, setJob] = useState<{ slips: KotSlip[]; info: KotPrintInfo; done: () => void } | null>(null);
  useEffect(() => {
    if (!job) return;
    let alive = true;
    const t = window.setTimeout(async () => {
      try {
        await runPrint(job.slips, job.info);
      } finally {
        if (alive) {
          job.done();
          setJob(null);
        }
      }
    }, 60);
    return () => {
      alive = false;
      window.clearTimeout(t);
    };
  }, [job]);
  return {
    print: (slips: KotSlip[], info: KotPrintInfo) => new Promise<void>((resolve) => setJob({ slips, info, done: resolve })),
    node: job ? <KotTicketsPrint slips={job.slips} info={job.info} /> : null,
  };
}
