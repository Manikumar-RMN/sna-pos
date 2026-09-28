"use client";

import Link from "next/link";
import { money, orderTypeLabel } from "@/lib/format";
import { UpiQr } from "../upi-qr";

export type ReceiptData = {
  invoiceTitle: string | null;
  header: string;
  legalName: string;
  taxIdLabel: string;
  taxId: string | null;
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
  items: { name: string; options: string | null; qty: number; unitPrice: number; amount: number }[];
  /** Tax components summed over the bill. */
  taxLines: { name: string; amount: number }[];
  subtotal: number;
  /** Ordinary discount (not the senior/PWD one). */
  discount: number;
  serviceCharge: number;
  serviceChargeLabel: string;
  taxTotal: number;
  /** Part of taxTotal already contained in menu prices. */
  taxIncluded: number;
  rounding: number;
  grandTotal: number;
  netSales: number;
  /** Philippines senior citizen / PWD. */
  senior: { kind: string; name: string; idNo: string } | null;
  seniorDiscount: number;
  vatRemoved: number;
  exemptSales: number;
  showVatBreakdown: boolean;
  payments: { methodName: string; amount: number; tendered: number | null; change: number; cashRounding: number }[];
  /** Still to pay on an unpaid or part-paid bill. */
  balance: number;
  refunded: number;
  state: "paid" | "unpaid" | "part-paid" | "voided" | "refunded" | "part-refunded";
  voidReason: string | null;
  footer: string | null;
  /** India: the restaurant's UPI ID, for a scan-to-pay QR on unpaid bills. */
  upi?: { id: string; payee: string } | null;
  /** India: FSSAI licence and SAC code printed on the bill. */
  fssaiNo?: string | null;
  sacCode?: string | null;
  /** B2B bill: the customer's tax ID (GSTIN) and business name. */
  buyer?: { taxId: string; name: string | null } | null;
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
  const m = (n: number) => money(n, c);
  const whenStr = new Date(data.createdAt).toLocaleString("en-IN", {
    timeZone: data.timezone,
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

  const taxAdded = Math.round((data.taxTotal - data.taxIncluded) * 100) / 100;
  const allIncluded = data.taxIncluded > 0 && taxAdded === 0;
  const allAdded = data.taxIncluded === 0;
  const vatable = Math.round((data.netSales - data.exemptSales + data.seniorDiscount) * 100) / 100;

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
        {(data.state === "unpaid" || data.state === "part-paid") && (
          <div className="mb-2 border-2 border-dashed py-1 text-center text-[12px] font-bold" style={{ borderColor: "#111" }}>
            {data.state === "part-paid" ? `PART PAID — BALANCE ${m(data.balance)}` : "UNPAID — NOT A TAX INVOICE"}
          </div>
        )}

        <div className="text-center">
          {data.invoiceTitle && data.state !== "unpaid" && data.state !== "part-paid" && (
            <div className="mb-1 text-[11px] font-bold uppercase tracking-wide">{data.invoiceTitle}</div>
          )}
          <div className="text-base font-bold">{data.header}</div>
          {data.legalName && data.legalName !== data.header && <div className="text-[11px]">{data.legalName}</div>}
          <div className="text-[11px]">{data.branchName}</div>
          {data.address && <div className="text-[11px]">{data.address}</div>}
          {data.phone && <div className="text-[11px]">Ph: {data.phone}</div>}
          {data.taxId && (
            <div className="text-[11px]">
              {data.taxIdLabel}: {data.taxId}
            </div>
          )}
          {data.fssaiNo && <div className="text-[11px]">FSSAI Lic. No.: {data.fssaiNo}</div>}
          {data.sacCode && data.taxId && <div className="text-[11px]">SAC: {data.sacCode}</div>}
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
        {data.buyer && (
          <div className="mt-1 text-[11px]">
            Bill to: {data.buyer.name ?? ""}
            <br />
            {data.taxIdLabel}: {data.buyer.taxId}
          </div>
        )}

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
                <td className="pr-1 align-top">
                  {it.name}
                  {it.options && <div className="text-[10px]">&nbsp;&nbsp;{it.options}</div>}
                </td>
                <td className="text-center align-top">{it.qty}</td>
                <td className="text-right align-top">{m(it.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <Rule />

        <div className="space-y-0.5 text-[11px]">
          <Row label="Subtotal" value={m(data.subtotal)} />
          {data.discount > 0 && <Row label="Discount" value={`-${m(data.discount)}`} />}
          {data.vatRemoved > 0 && <Row label="Less: VAT (exempt)" value={`-${m(data.vatRemoved)}`} />}
          {data.seniorDiscount > 0 && (
            <Row label={`Less: ${data.senior?.kind === "pwd" ? "PWD" : "Senior"} 20%`} value={`-${m(data.seniorDiscount)}`} />
          )}
          {data.serviceCharge > 0 && <Row label={data.serviceChargeLabel} value={m(data.serviceCharge)} />}
          {allAdded && data.taxLines.map((t, i) => <Row key={i} label={t.name} value={m(t.amount)} />)}
          {!allAdded && !allIncluded && taxAdded > 0 && <Row label="Tax on service charge" value={m(taxAdded)} />}
          {Math.abs(data.rounding) >= 0.005 && (
            <Row label="Rounding" value={`${data.rounding > 0 ? "+" : "-"}${m(Math.abs(data.rounding))}`} />
          )}
        </div>

        <div className="my-1 border-t" style={{ borderColor: "#111" }} />
        <div className="flex justify-between text-sm font-bold">
          <span>TOTAL</span>
          <span>{m(data.grandTotal)}</span>
        </div>

        {data.taxIncluded > 0 && !data.showVatBreakdown && (
          <div className="mt-1 space-y-0.5 text-[10px]" style={{ color: "#444" }}>
            {allIncluded ? (
              data.taxLines.map((t, i) => <Row key={i} label={`Includes ${t.name}`} value={m(t.amount)} />)
            ) : (
              <Row label="Includes tax" value={m(data.taxIncluded)} />
            )}
          </div>
        )}

        {data.payments.length > 0 && (
          <>
            <Rule />
            <div className="space-y-0.5 text-[11px]">
              {data.payments.map((p, i) => (
                <div key={i} className="space-y-0.5">
                  {Math.abs(p.cashRounding) >= 0.005 && (
                    <Row label="Cash rounding" value={`${p.cashRounding > 0 ? "+" : "-"}${m(Math.abs(p.cashRounding))}`} />
                  )}
                  <Row label={`Paid (${p.methodName})`} value={m(p.amount)} />
                  {p.tendered != null && p.tendered > 0 && <Row label="Tendered" value={m(p.tendered)} />}
                  {p.change > 0 && <Row label="Change" value={m(p.change)} />}
                </div>
              ))}
              {data.state === "part-paid" && <Row label="Balance to pay" value={m(data.balance)} />}
              {data.refunded > 0 && <Row label="Refunded" value={`-${m(data.refunded)}`} />}
            </div>
          </>
        )}

        {data.showVatBreakdown && (
          <>
            <Rule />
            <div className="space-y-0.5 text-[11px]">
              <Row label="VATable sales" value={m(vatable)} />
              <Row label="VAT" value={m(data.taxTotal)} />
              <Row label="VAT-exempt sales" value={m(data.exemptSales)} />
              <Row label="Zero-rated sales" value={m(0)} />
            </div>
            {data.senior && (
              <div className="mt-2 text-[11px]">
                {data.senior.kind === "pwd" ? "PWD" : "Senior citizen"}: {data.senior.name}
                <br />
                ID no.: {data.senior.idNo}
                <div className="mt-3 border-t pt-0.5 text-center text-[10px]" style={{ borderColor: "#111" }}>
                  Signature
                </div>
              </div>
            )}
          </>
        )}

        {data.upi && (data.state === "unpaid" || data.state === "part-paid") && data.balance > 0 && (
          <>
            <Rule />
            <div className="flex justify-center py-1">
              <UpiQr upiId={data.upi.id} payee={data.upi.payee} amount={data.balance} note={`Bill ${data.billNumber}`} size={140} />
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
    <div className="flex justify-between gap-2">
      <span>{label}</span>
      <span className="whitespace-nowrap">{value}</span>
    </div>
  );
}
