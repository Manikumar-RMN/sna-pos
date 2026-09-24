"use client";

import Link from "next/link";
import { money, orderTypeLabel } from "@/lib/format";

export type ReceiptData = {
  header: string;
  legalName: string;
  gstin: string | null;
  branchName: string;
  address: string | null;
  phone: string | null;
  billNumber: string;
  orderType: string;
  tableNumber: string | null;
  createdAt: string;
  timezone: string;
  currency: string;
  cashierName: string;
  items: { name: string; qty: number; unitPrice: number; amount: number }[];
  taxLines: { name: string; amount: number }[];
  subtotal: number;
  discount: number;
  taxTotal: number;
  rounding: number;
  grandTotal: number;
  payment: { methodName: string; tendered: number | null; change: number } | null;
  refunded: number;
  state: "paid" | "unpaid" | "voided" | "refunded" | "part-refunded";
  voidReason: string | null;
  footer: string | null;
};

export function ReceiptView({
  data,
  backHref = "/pos",
  backLabel = "New bill",
  showNextBill = true,
}: {
  data: ReceiptData;
  backHref?: string;
  backLabel?: string;
  showNextBill?: boolean;
}) {
  const c = data.currency;
  const whenStr = new Date(data.createdAt).toLocaleString("en-IN", {
    timeZone: data.timezone,
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

  return (
    <div className="mx-auto max-w-sm">
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #receipt, #receipt * { visibility: visible !important; }
          #receipt { position: absolute; left: 0; top: 0; width: 80mm; border: 0 !important; box-shadow: none !important; }
          .no-print { display: none !important; }
        }
      `}</style>

      <div className="no-print mb-3 flex items-center justify-between">
        <Link href={backHref} className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
          ← {backLabel}
        </Link>
        <button onClick={() => window.print()} className="btn btn-primary h-10 px-4 text-sm">
          Print
        </button>
      </div>

      <div
        id="receipt"
        className="card mx-auto p-4"
        style={{ width: "302px", fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", color: "#111" }}
      >
        {data.state === "voided" && (
          <div className="mb-2 border-2 border-dashed py-1 text-center text-sm font-bold" style={{ borderColor: "#111" }}>
            VOIDED — NOT VALID
            {data.voidReason && <div className="text-[11px] font-normal">Reason: {data.voidReason}</div>}
          </div>
        )}
        {data.state === "unpaid" && (
          <div className="mb-2 border-2 border-dashed py-1 text-center text-[12px] font-bold" style={{ borderColor: "#111" }}>
            UNPAID — NOT A TAX INVOICE
          </div>
        )}

        <div className="text-center">
          <div className="text-base font-bold">{data.header}</div>
          {data.legalName && data.legalName !== data.header && <div className="text-[11px]">{data.legalName}</div>}
          <div className="text-[11px]">{data.branchName}</div>
          {data.address && <div className="text-[11px]">{data.address}</div>}
          {data.phone && <div className="text-[11px]">Ph: {data.phone}</div>}
          {data.gstin && <div className="text-[11px]">GSTIN: {data.gstin}</div>}
        </div>

        <Rule />

        <div className="flex justify-between text-[11px]">
          <span>Bill: {data.billNumber}</span>
          <span>
            {orderTypeLabel[data.orderType] ?? data.orderType}
            {data.tableNumber ? ` · T${data.tableNumber}` : ""}
          </span>
        </div>
        <div className="text-[11px]">{whenStr}</div>
        <div className="text-[11px]">Cashier: {data.cashierName}</div>

        <Rule />

        <table className="w-full text-[11px]">
          <thead>
            <tr className="text-left">
              <th className="font-semibold">Item</th>
              <th className="w-8 text-center font-semibold">Qty</th>
              <th className="w-16 text-right font-semibold">Amount</th>
            </tr>
          </thead>
          <tbody>
            {data.items.map((it, i) => (
              <tr key={i}>
                <td className="pr-1 align-top">{it.name}</td>
                <td className="text-center align-top">{it.qty}</td>
                <td className="text-right align-top">{money(it.amount, c)}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <Rule />

        <div className="space-y-0.5 text-[11px]">
          <Row label="Subtotal" value={money(data.subtotal, c)} />
          {data.discount > 0 && <Row label="Discount" value={`-${money(data.discount, c)}`} />}
          {data.taxLines.map((t, i) => (
            <Row key={i} label={t.name} value={money(t.amount, c)} />
          ))}
          {Math.abs(data.rounding) >= 0.005 && (
            <Row
              label="Rounding"
              value={`${data.rounding > 0 ? "+" : "-"}${money(Math.abs(data.rounding), c)}`}
            />
          )}
        </div>

        <div className="my-1 border-t" style={{ borderColor: "#111" }} />
        <div className="flex justify-between text-sm font-bold">
          <span>TOTAL</span>
          <span>{money(data.grandTotal, c)}</span>
        </div>

        {data.payment && (
          <>
            <Rule />
            <div className="space-y-0.5 text-[11px]">
              <Row label={`Paid (${data.payment.methodName})`} value={money(data.grandTotal, c)} />
              {data.payment.tendered != null && data.payment.tendered > 0 && (
                <Row label="Tendered" value={money(data.payment.tendered, c)} />
              )}
              {data.payment.change > 0 && <Row label="Change" value={money(data.payment.change, c)} />}
              {data.refunded > 0 && <Row label="Refunded" value={`-${money(data.refunded, c)}`} />}
            </div>
          </>
        )}

        <Rule />
        <div className="text-center text-[11px]">{data.footer || "Thank you — visit again"}</div>
        <div className="mt-1 text-center text-[10px]" style={{ color: "#666" }}>
          Billed on SNA POS
        </div>
      </div>

      {showNextBill && (
        <div className="no-print mx-auto mt-3 max-w-sm text-center">
          <Link href="/pos" className="btn btn-primary w-full">
            Start next bill
          </Link>
        </div>
      )}
    </div>
  );
}

function Rule() {
  return <div className="my-2 border-t border-dashed" style={{ borderColor: "#999" }} />;
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between">
      <span>{label}</span>
      <span>{value}</span>
    </div>
  );
}
