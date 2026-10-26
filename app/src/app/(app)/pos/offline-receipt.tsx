"use client";

import { useRef, useState } from "react";
import { money, orderTypeLabel } from "@/lib/format";
import { billFormat, billTextPx, paperWidth } from "@/lib/bill-format";
import type { OfflineBill, Snapshot } from "@/lib/offline";
import { readDevicePrint } from "@/lib/device-print";
import { offlineBillLines, offlineKotLines, sendToRawbt } from "@/lib/rawbt";
import { enqueuePrint, markAppPrint, newPrintRef, useBrowserPrint, type PrintKind } from "@/lib/print-log";

/** Bill and kitchen tickets for a bill made offline, printed from this device. */
export function OfflineReceipt({ bill, snap, onDone }: { bill: OfflineBill; snap: Snapshot; onDone: () => void }) {
  const [target, setTarget] = useState<"bill" | "kot">("bill");
  const [printNote, setPrintNote] = useState<string | null>(null);
  // Prints made from this receipt so far. The first bill print is the normal one; every later one (and any later kitchen ticket) is a reprint.
  const printed = useRef<Record<PrintKind, number>>({ bill: 0, kot: 0 });
  const r = snap.receipt;
  const m = (n: number) => money(n, r.currency);
  const when = new Date(bill.created_at).toLocaleString("en-IN", { timeZone: r.timezone, day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
  const c = bill.calc;
  const addedTax = Math.round((c.tax_total - c.tax_included) * 100) / 100;
  // The owner's bill layout (Settings → Bill layout): paper width, text size, logo, registered name, rate column.
  const f = billFormat(r.format);
  const paper = paperWidth(f);
  const typeLabel = orderTypeLabel[bill.order_type] ?? bill.order_type;
  // The packing charge is on the bill but is not food, so it stays off the kitchen ticket.
  const kotItems = bill.items.filter((i) => i.product_id !== snap.settings.packing?.product_id);
  const stations = [...new Set(kotItems.map((i) => i.station))];
  const kotItemPx = f.kot_text === "large" ? 19 : 15;
  const kotNotePx = f.kot_text === "large" ? 17 : 13;
  /**
   * Offline there is no server to ask, so each print is written to the queue on this device (lib/print-log.ts); OfflineSync records it
   * through log_print once the bill itself has reached the server (matched by the bill's client_id). The first bill print is silent.
   * The first kitchen ticket is the normal send to the kitchen and is not a reprint, so only later ones are queued.
   */
  const noteForLog = (kind: PrintKind, declared: boolean) => {
    const n = printed.current[kind];
    printed.current[kind] = n + 1;
    if (kind === "kot" && n === 0 && !declared) return;
    const ok = enqueuePrint({ ref: newPrintRef(), kind, at: new Date().toISOString(), billClientRef: bill.client_id, isReprint: n > 0, declared });
    if (declared) setPrintNote(ok ? "Printed from the browser menu. It will be recorded when this bill reaches the server." : "Printed from the browser menu, but this device could not save the record (storage full).");
  };
  // Ctrl+P / browser menu on this receipt: cannot be held back, so it is queued as a declared print of what is on screen.
  useBrowserPrint(true, () => noteForLog(target, true));
  const print = (t: "bill" | "kot") => {
    noteForLog(t, false);
    if (readDevicePrint().method === "rawbt") {
      const { lines, width } = t === "bill" ? offlineBillLines(bill, snap) : offlineKotLines(bill, snap);
      sendToRawbt(lines, width);
      return;
    }
    setTarget(t);
    setTimeout(() => {
      markAppPrint(); // already queued above: the Ctrl+P listener must not queue it again
      window.print();
    }, 50);
  };

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto p-4" style={{ background: "rgba(10,8,20,.55)" }}>
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #${target === "bill" ? "off-bill" : "off-kot"}, #${target === "bill" ? "off-bill" : "off-kot"} * { visibility: visible !important; }
          #${target === "bill" ? "off-bill" : "off-kot"} { position: absolute; left: 0; top: 0; width: ${paper.printMm}mm; }
          .kot-page { page-break-after: always; }
        }
      `}</style>
      <div className="mx-auto max-w-sm space-y-3">
        <div className="no-print rounded-xl px-3 py-2 text-sm" style={{ background: "var(--color-warn-soft)" }}>
          Saved offline on this device. It is sent to the server by itself when the internet is back.
        </div>
        {printNote && (
          <div className="no-print rounded-xl px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)" }}>
            {printNote}
          </div>
        )}
        {/* Sizes are in em so the owner's text size applies to the whole bill, as on the online bill. */}
        <div
          id="off-bill"
          className="card p-4"
          style={{ width: paper.screenPx, fontSize: billTextPx(f), fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", color: "#111", background: "#fff" }}
        >
          <div className="text-center">
            {r.invoice_title && <div className="mb-1 text-[1em] font-bold uppercase tracking-wide">{r.invoice_title}</div>}
            {f.logo && r.logo && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={r.logo} alt="" className="mx-auto mb-1.5 block" style={{ maxHeight: 64, maxWidth: "70%" }} />
            )}
            <div className="text-[1.45em] font-bold">{r.header}</div>
            {f.legal_name && r.legal_name && r.legal_name !== r.header && <div className="text-[1em]">{r.legal_name}</div>}
            {r.tax_id && (
              <div className="text-[1em]">
                {r.tax_id_label ?? "Tax No."}: {r.tax_id}
              </div>
            )}
            {r.fssai_no && <div className="text-[1em]">FSSAI Lic. No.: {r.fssai_no}</div>}
          </div>
          <Rule />
          <div className="flex justify-between text-[1em]">
            <span>Bill: {bill.number}</span>
            <span>{typeLabel}</span>
          </div>
          <div className="text-[1em]">{when}</div>
          {f.guest && bill.guest && (bill.guest.name || bill.guest.phone || bill.guest.address) && (
            <div className="mt-1 text-[1em]">
              {(bill.guest.name || bill.guest.phone) && <div>Guest: {[bill.guest.name, bill.guest.phone].filter(Boolean).join(" · ")}</div>}
              {bill.guest.address && <div>Deliver to: {bill.guest.address}</div>}
            </div>
          )}
          <Rule />
          <table className="w-full text-[1em]">
            <tbody>
              {bill.items.map((it, i) => (
                <tr key={i}>
                  <td className="pr-1 align-top">
                    {it.name}
                    {it.options_text && <div className="text-[0.91em]">{it.options_text}</div>}
                  </td>
                  <td className="w-8 text-center align-top">{it.qty}</td>
                  {f.rate && <td className="w-12 text-right align-top">{it.price.toFixed(2)}</td>}
                  <td className="w-16 text-right align-top">{m(c.lines[i]?.subtotal ?? it.price * it.qty)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <Rule />
          <div className="space-y-0.5 text-[1em]">
            <Row label="Subtotal" value={m(c.subtotal)} />
            {c.discount > 0 && <Row label="Discount" value={`-${m(c.discount)}`} />}
            {c.service_charge > 0 && <Row label={snap.settings.sc_label} value={m(c.service_charge)} />}
            {c.taxes
              .filter((t) => t.amount !== 0)
              .map((t, i) => (
                <Row key={i} label={`${t.name} (${t.rate}%)`} value={m(t.amount)} />
              ))}
            {Math.abs(c.rounding) >= 0.005 && <Row label="Rounding" value={m(c.rounding)} />}
            {Math.abs(bill.due - bill.grand_total) >= 0.005 && <Row label="Cash rounding" value={m(bill.due - bill.grand_total)} />}
          </div>
          <div className="mt-1 flex justify-between text-[1.27em] font-bold">
            <span>Total</span>
            <span>{m(bill.due)}</span>
          </div>
          {c.tax_included > 0 && addedTax === 0 && <div className="text-right text-[0.91em]">Prices include tax {m(c.tax_included)}</div>}
          <Rule />
          {/* Paid and change have always printed larger than the rest on the offline bill; kept that way. */}
          <div className="text-[1.45em]">
            <Row label={`Paid (${bill.method_name})`} value={m(bill.due)} />
            {bill.tendered != null && bill.tendered > bill.due && <Row label="Change" value={m(bill.tendered - bill.due)} />}
          </div>
          <Rule />
          <div className="text-center text-[1em]">{r.footer || "Thank you — visit again"}</div>
        </div>

        <div id="off-kot" className="card p-3" style={{ width: paper.screenPx, background: "#fff", color: "#000" }}>
          {stations.map((s) => (
            <div key={s} className="kot-page mb-2 font-mono">
              <div className="text-center text-[16px] font-bold">KOT · {s}</div>
              <div className="text-[12px]">
                {bill.number} · {typeLabel} · {when}
              </div>
              <div className="my-1 border-t border-dashed border-black" />
              {kotItems
                .filter((i) => i.station === s)
                .map((i, idx) => (
                  <div key={idx} style={{ fontSize: kotItemPx }}>
                    <b>{i.qty} ×</b> {i.name}
                    {i.options_text && ` (${i.options_text})`}
                    {i.note && (
                      <div className="pl-4 font-bold" style={{ fontSize: kotNotePx }}>
                        ** {i.note}
                      </div>
                    )}
                  </div>
                ))}
            </div>
          ))}
        </div>

        <div className="no-print grid grid-cols-2 gap-2">
          <button className="btn btn-primary" onClick={() => print("bill")}>
            Print bill
          </button>
          <button className="btn border" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }} onClick={() => print("kot")}>
            Print kitchen ticket
          </button>
          <button className="btn btn-pay col-span-2" onClick={onDone}>
            Next bill
          </button>
        </div>
      </div>
    </div>
  );
}

function Rule() {
  return <div className="my-2 border-t border-dashed" style={{ borderColor: "#999" }} />;
}
function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-2">
      <span>{label}</span>
      <span className="whitespace-nowrap">{value}</span>
    </div>
  );
}
