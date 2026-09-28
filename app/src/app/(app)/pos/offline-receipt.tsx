"use client";

import { useState } from "react";
import { money } from "@/lib/format";
import type { OfflineBill, Snapshot } from "@/lib/offline";

/** Bill and kitchen tickets for a bill made offline, printed from this device. */
export function OfflineReceipt({ bill, snap, onDone }: { bill: OfflineBill; snap: Snapshot; onDone: () => void }) {
  const [target, setTarget] = useState<"bill" | "kot">("bill");
  const r = snap.receipt;
  const m = (n: number) => money(n, r.currency);
  const when = new Date(bill.created_at).toLocaleString("en-IN", { timeZone: r.timezone, day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
  const c = bill.calc;
  const addedTax = Math.round((c.tax_total - c.tax_included) * 100) / 100;
  const stations = [...new Set(bill.items.map((i) => i.station))];
  const print = (t: "bill" | "kot") => {
    setTarget(t);
    setTimeout(() => window.print(), 50);
  };

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto p-4" style={{ background: "rgba(10,8,20,.55)" }}>
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #${target === "bill" ? "off-bill" : "off-kot"}, #${target === "bill" ? "off-bill" : "off-kot"} * { visibility: visible !important; }
          #${target === "bill" ? "off-bill" : "off-kot"} { position: absolute; left: 0; top: 0; width: 80mm; }
          .kot-page { page-break-after: always; }
        }
      `}</style>
      <div className="mx-auto max-w-sm space-y-3">
        <div className="no-print rounded-xl px-3 py-2 text-sm" style={{ background: "var(--color-warn-soft)" }}>
          Saved offline on this device. It is sent to the server by itself when the internet is back.
        </div>
        <div id="off-bill" className="card p-4" style={{ width: 302, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", color: "#111", background: "#fff" }}>
          <div className="text-center">
            {r.invoice_title && <div className="mb-1 text-[11px] font-bold uppercase tracking-wide">{r.invoice_title}</div>}
            <div className="text-base font-bold">{r.header}</div>
            {r.legal_name && r.legal_name !== r.header && <div className="text-[11px]">{r.legal_name}</div>}
            {r.tax_id && (
              <div className="text-[11px]">
                {r.tax_id_label ?? "Tax No."}: {r.tax_id}
              </div>
            )}
            {r.fssai_no && <div className="text-[11px]">FSSAI Lic. No.: {r.fssai_no}</div>}
          </div>
          <Rule />
          <div className="flex justify-between text-[11px]">
            <span>Bill: {bill.number}</span>
            <span>{bill.order_type === "dine_in" ? "Dine-in" : "Takeaway"}</span>
          </div>
          <div className="text-[11px]">{when}</div>
          <Rule />
          <table className="w-full text-[11px]">
            <tbody>
              {bill.items.map((it, i) => (
                <tr key={i}>
                  <td className="pr-1 align-top">
                    {it.name}
                    {it.options_text && <div className="text-[10px]">{it.options_text}</div>}
                  </td>
                  <td className="w-8 text-center align-top">{it.qty}</td>
                  <td className="w-16 text-right align-top">{m(c.lines[i]?.subtotal ?? it.price * it.qty)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <Rule />
          <div className="space-y-0.5 text-[11px]">
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
          <div className="mt-1 flex justify-between text-sm font-bold">
            <span>Total</span>
            <span>{m(bill.due)}</span>
          </div>
          {c.tax_included > 0 && addedTax === 0 && <div className="text-right text-[10px]">Prices include tax {m(c.tax_included)}</div>}
          <Rule />
          <Row label={`Paid (${bill.method_name})`} value={m(bill.due)} />
          {bill.tendered != null && bill.tendered > bill.due && <Row label="Change" value={m(bill.tendered - bill.due)} />}
          <Rule />
          <div className="text-center text-[11px]">{r.footer || "Thank you — visit again"}</div>
        </div>

        <div id="off-kot" className="card p-3" style={{ width: 302, background: "#fff", color: "#000" }}>
          {stations.map((s) => (
            <div key={s} className="kot-page mb-2 font-mono">
              <div className="text-center text-[16px] font-bold">KOT · {s}</div>
              <div className="text-[12px]">
                {bill.number} · {bill.order_type === "dine_in" ? "Dine-in" : "Takeaway"} · {when}
              </div>
              <div className="my-1 border-t border-dashed border-black" />
              {bill.items
                .filter((i) => i.station === s)
                .map((i, idx) => (
                  <div key={idx} className="text-[15px]">
                    <b>{i.qty} ×</b> {i.name}
                    {i.options_text && ` (${i.options_text})`}
                    {i.note && <div className="pl-4 text-[13px] font-bold">** {i.note}</div>}
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
