"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { readDevicePrint } from "@/lib/device-print";
import { billLines, sendToRawbt } from "@/lib/rawbt";
import { money, orderTypeLabel } from "@/lib/format";
import { billFormat, billTextPx, paperWidth, type BillFormat } from "@/lib/bill-format";
import { UpiQr } from "../upi-qr";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { logPrint } from "../bills/log-print";
import { ReprintReasonPrompt, needsReason } from "../reprint-reason";
import { loyaltyLines, type ReceiptLoyalty } from "@/lib/receipt-loyalty";
import { dropPrint, markAppPrint, recordDeclaredPrint, useBrowserPrint } from "@/lib/print-log";

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
  /** unit: "kg" for items sold by weight. */
  items: { name: string; local?: string | null; options: string | null; qty: number; unit?: string | null; unitPrice: number; amount: number; offerName?: string | null; listPrice?: number | null }[];
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
  /** Complimentary bill or staff meal: no money was taken. */
  comp?: { kind: "complimentary" | "staff_meal"; reason: string } | null;
  footer: string | null;
  /** India: the restaurant's UPI ID, for a scan-to-pay QR on unpaid bills. */
  upi?: { id: string; payee: string } | null;
  /** India: FSSAI licence and SAC code printed on the bill. */
  fssaiNo?: string | null;
  sacCode?: string | null;
  /** B2B bill: the customer's tax ID (GSTIN) and business name. */
  buyer?: { taxId: string; name: string | null } | null;
  /** The owner's layout choices (Settings → Bill layout). Missing = the standard layout. */
  format?: BillFormat | null;
  /** The restaurant's logo as a small picture (data URL), if one was uploaded. */
  logo?: string | null;
  /** Guest name, phone and delivery address taken at the counter. */
  guest?: { name: string | null; phone: string | null; address: string | null } | null;
  /** Token number for the day (takeaway counters), if the outlet uses tokens. */
  token?: number | null;
  /**
   * Loyalty points used as a discount before tax (the guest's points paid part of the bill). Shown as its own
   * "Loyalty points discount" line; `discount` above stays the ordinary (manual) part. Absent or 0 = no line.
   */
  loyaltyDiscount?: number;
  /**
   * Points for this guest: earned and used on THIS bill, and the balance after it. Supplied by the bill screen
   * (absent when the loyalty add-on is off or no guest is on the bill). Printed as a small block under the payments.
   */
  loyalty?: ReceiptLoyalty | null;
};

export function ReceiptView({
  data,
  backHref = "/pos",
  backLabel = "New bill",
  showNextBill = true,
  orderId,
  hideBack = false,
}: {
  data: ReceiptData;
  backHref?: string;
  backLabel?: string;
  showNextBill?: boolean;
  /** The bill's id. When given, every print is recorded first (first print silent, later ones are reprints: right or manager PIN). */
  orderId?: string;
  /** The single order screen shows the receipt in a side panel and has its own way back. */
  hideBack?: boolean;
}) {
  const [needsPin, setNeedsPin] = useState(false);
  const [askReason, setAskReason] = useState(false);
  const printedHere = useRef(false);
  const [printError, setPrintError] = useState<string | null>(null);
  /** Winsar "Estimate": the same bill printed as a proforma, marked clearly as not a tax invoice. */
  const [estimate, setEstimate] = useState(false);
  // Ctrl+P / browser-menu print: what happened to its log entry (shown as a small notice, never blocks the print).
  const [declaredNote, setDeclaredNote] = useState<{ text: string; ref?: string; needsPin?: boolean } | null>(null);
  const [pinForDeclared, setPinForDeclared] = useState<string | null>(null);
  const c = data.currency;
  const m = (n: number) => money(n, c);
  const f = billFormat(data.format);
  const paper = paperWidth(f);
  const px = billTextPx(f);

  // Counter set to print bills (Settings → Printers): print once, straight after payment.
  useEffect(() => {
    const url = new URL(window.location.href);
    if (url.searchParams.get("print") !== "1") return;
    url.searchParams.delete("print");
    window.history.replaceState(null, "", url.toString());
    if (readDevicePrint().bills && (data.state === "paid" || data.state === "part-paid")) {
      const t = setTimeout(() => void printBillLogged(), 300);
      return () => clearTimeout(t);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data.state]);

  /**
   * Print button and the print after payment. The database counts earlier prints (log_print, migration 135): the first print of a
   * bill is silent, a later one is a reprint that needs the right or a manager PIN and is written to the audit log. Prints only
   * when the log is written. Ctrl+P / the browser's own menu is recorded by logDeclaredPrint ("beforeprint"); a bill shown without an id (the layout preview) is not logged.
   */
  async function printBillLogged(reason?: string) {
    setPrintError(null);
    setEstimate(false);
    if (!orderId) return printBill();
    let res: Awaited<ReturnType<typeof logPrint>>;
    try {
      res = await logPrint({ kind: "bill", orderId, isReprint: printedHere.current, reason });
    } catch {
      return setPrintError("Could not record the print. Check the internet and try again.");
    }
    if (!res.ok) {
      if (needsReason(res.error)) return setAskReason(true);
      if (neededRight(res.error) === "order.reprint") return setNeedsPin(true);
      return setPrintError(cleanMessage(res.error));
    }
    printedHere.current = true; // any later press on this screen is declared a reprint, whatever the log shows
    printBill();
  }

  /** Prints the bill the way this device is set up to (Settings → Printers). */
  function printBill(asEstimate = false) {
    if (readDevicePrint().method === "rawbt") {
      const { lines, width } = billLines(data, asEstimate);
      sendToRawbt(lines, width);
    } else {
      // The print was logged just before: the "beforeprint" listener below must not log it a second time.
      markAppPrint();
      window.print();
    }
  }

  /**
   * Ctrl+P or the browser menu: the print cannot be held back, so it is recorded afterwards. It is declared a reprint when this
   * screen already printed the bill; otherwise the database decides (first print silent, later ones reprints). A role without the
   * reprint right gets a notice with a manager PIN button, and the print waits in the device queue until it is recorded.
   */
  // The Check screen of the single order screen has its own Estimate and Print buttons: they ask this receipt to print.
  const printRef = useRef({ print: () => {}, estimate: () => {} });
  printRef.current = {
    print: () => void printBillLogged(),
    estimate: () => setEstimate(true),
  };
  /** Estimate: a proforma for the guest to look at. It is not the bill, so it is never written to the print log (a real Print after it is still the first print). */
  function printEstimate() {
    printBill(true);
  }
  useEffect(() => {
    if (!hideBack) return;
    const onPrint = () => void printRef.current.print();
    const onEstimate = () => printRef.current.estimate();
    window.addEventListener("sna-desk-print", onPrint);
    window.addEventListener("sna-desk-estimate", onEstimate);
    return () => {
      window.removeEventListener("sna-desk-print", onPrint);
      window.removeEventListener("sna-desk-estimate", onEstimate);
    };
  }, [hideBack]);

  async function logDeclaredPrint() {
    if (!orderId) return;
    const out = await recordDeclaredPrint({ kind: "bill", orderId, isReprint: printedHere.current }, (e) =>
      logPrint({ kind: "bill", orderId: e.orderId, isReprint: e.isReprint, auto: true }),
    );
    if (out.status === "recorded") {
      printedHere.current = true;
      return setDeclaredNote(out.reprint ? { text: `Printed from the browser menu: recorded as reprint (copy ${out.printNo ?? "2+"}).` } : null);
    }
    if (out.status === "offline") return setDeclaredNote({ text: "Printed from the browser menu. The record is saved on this device and is sent when the internet is back." });
    if (out.status === "needs_approval")
      return setDeclaredNote({ text: "Printed from the browser menu, not recorded yet: a reprint needs the reprint right or a manager PIN.", ref: out.ref, needsPin: true });
    setDeclaredNote({ text: `Printed from the browser menu, not recorded yet: ${cleanMessage(out.error)}` });
  }
  useBrowserPrint(!!orderId, () => void logDeclaredPrint());

  /** The manager PIN was entered for a browser-menu print: record it now (one-time approval). */
  async function recordDeclaredWithPin(ref: string) {
    if (!orderId) return;
    try {
      const res = await logPrint({ kind: "bill", orderId, isReprint: true, auto: true });
      if (res.ok) {
        dropPrint(ref);
        printedHere.current = true;
        return setDeclaredNote({ text: `Browser-menu print recorded as reprint (copy ${res.printNo ?? "2+"}).` });
      }
      setDeclaredNote({ text: `Not recorded: ${cleanMessage(res.error)}`, ref, needsPin: neededRight(res.error) === "order.reprint" });
    } catch {
      setDeclaredNote({ text: "Not recorded: could not reach the server. It stays queued on this device.", ref });
    }
  }
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
    <div
      className={hideBack && estimate ? "fixed inset-0 z-[70] overflow-y-auto p-4 [&>*]:mx-auto " : "mx-auto max-w-sm"}
      style={hideBack && estimate ? { background: "rgba(10,8,20,.55)" } : undefined}
    >
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #receipt, #receipt * { visibility: visible !important; }
          #receipt { position: absolute; left: 0; top: 0; width: ${paper.printMm}mm; border: 0 !important; box-shadow: none !important; }
          .no-print { display: none !important; }
        }
      `}</style>

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
            void printBillLogged();
          }}
        />
      )}
      {askReason && (
        <ReprintReasonPrompt
          what="this bill"
          onCancel={() => setAskReason(false)}
          onConfirm={(r) => {
            setAskReason(false);
            void printBillLogged(r);
          }}
        />
      )}
      {estimate && (
        <div className={`no-print mb-3 flex flex-wrap items-center justify-between gap-2 rounded-lg px-3 py-2 text-sm ${hideBack ? "mt-6" : ""}`} role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-ink)", ...(hideBack ? { width: `${paper.screenPx + 32}px`, maxWidth: "100%" } : {}) }}>
          <span className="font-semibold">Estimate preview: not a tax invoice, not counted as a print.</span>
          <span className="flex gap-2">
            <button className="btn btn-primary h-9 px-3 text-sm" onClick={printEstimate}>
              Print estimate
            </button>
            <button className="btn border h-9 px-3 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setEstimate(false)}>
              Close
            </button>
          </span>
        </div>
      )}
      <div className={`no-print mb-3 items-center ${hideBack ? (estimate ? "hidden" : "flex justify-end") : "flex justify-between"}`}>
        {!hideBack && (
          <Link href={backHref} className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
            ← {backLabel}
          </Link>
        )}
        <span className="flex gap-2">
          {(data.state === "unpaid" || data.state === "part-paid") && (
            <button
              onClick={() => setEstimate(true)}
              className="btn border h-10 px-4 text-sm"
              style={{ borderColor: "var(--color-brand)", color: "var(--color-brand-strong)" }}
              title="Show the bill as an estimate (preview) with a Print option. It is not a tax invoice, takes no payment and is not counted as a print."
            >
              Estimate
            </button>
          )}
          <button onClick={() => void printBillLogged()} className="btn btn-primary h-10 px-4 text-sm">
            Print
          </button>
        </span>
      </div>
      {declaredNote && (
        <p className="no-print mb-3 flex flex-wrap items-center justify-between gap-2 rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-ink)" }}>
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
      {printError && (
        <p className="no-print mb-3 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {printError}
        </p>
      )}

      <div
        id="receipt"
        className="card mx-auto p-4"
        style={{ width: `${paper.screenPx}px`, fontSize: `${px}px`, fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace", color: "#111" }}
      >
        {data.state === "voided" && (
          <div className="mb-2 border-2 border-dashed py-1 text-center text-[1.27em] font-bold" style={{ borderColor: "#111" }}>
            VOIDED — NOT VALID
            {data.voidReason && <div className="text-[1em] font-normal">Reason: {data.voidReason}</div>}
          </div>
        )}
        {data.comp && data.state !== "voided" && (
          <div className="mb-2 border-2 border-dashed py-1 text-center text-[1.09em] font-bold" style={{ borderColor: "#111" }}>
            {data.comp.kind === "complimentary" ? "COMPLIMENTARY — NO CHARGE" : "STAFF MEAL — NO CHARGE"}
            {data.comp.reason && <div className="text-[1em] font-normal">{data.comp.reason}</div>}
          </div>
        )}
        {(data.state === "unpaid" || data.state === "part-paid") && (
          <div className="mb-2 border-2 border-dashed py-1 text-center text-[1.09em] font-bold" style={{ borderColor: "#111" }}>
            {estimate ? "ESTIMATE — NOT A TAX INVOICE" : data.state === "part-paid" ? `PART PAID — BALANCE ${m(data.balance)}` : "UNPAID — NOT A TAX INVOICE"}
          </div>
        )}

        <div className="text-center">
          {data.invoiceTitle && data.state !== "unpaid" && data.state !== "part-paid" && (
            <div className="mb-1 text-[1em] font-bold uppercase tracking-wide">{data.invoiceTitle}</div>
          )}
          {f.logo && data.logo && (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={data.logo} alt="" className="mx-auto mb-1.5 block" style={{ maxHeight: 64, maxWidth: "70%" }} />
          )}
          <div className="text-[1.45em] font-bold">
            {data.header}
          </div>
          {f.legal_name && data.legalName && data.legalName !== data.header && <div className="text-[1em]">{data.legalName}</div>}
          {f.branch && <div className="text-[1em]">{data.branchName}</div>}
          {f.address && data.address && <div className="text-[1em]">{data.address}</div>}
          {f.phone && data.phone && <div className="text-[1em]">Ph: {data.phone}</div>}
          {data.taxId && (
            <div className="text-[1em]">
              {data.taxIdLabel}: {data.taxId}
            </div>
          )}
          {data.fssaiNo && <div className="text-[1em]">FSSAI Lic. No.: {data.fssaiNo}</div>}
          {data.sacCode && data.taxId && <div className="text-[1em]">SAC: {data.sacCode}</div>}
        </div>

        <Rule />

        <div className="flex justify-between text-[1em]">
          <span>Bill: {data.billNumber}</span>
          <span>
            {orderTypeLabel[data.orderType] ?? data.orderType}
            {data.tableNumber ? ` · T${data.tableNumber}` : ""}
          </span>
        </div>
        <div className="text-[1em]">{whenStr}</div>
        {f.cashier && <div className="text-[1em]">Cashier: {data.cashierName}</div>}
        {data.token != null && (
          <div className="mt-1 border-2 py-0.5 text-center text-[1.8em] font-bold" style={{ borderColor: "#111" }}>
            TOKEN {data.token}
          </div>
        )}
        {f.guest && data.guest && (data.guest.name || data.guest.phone || data.guest.address) && (
          <div className="mt-1 text-[1em]">
            {(data.guest.name || data.guest.phone) && (
              <div>
                Guest: {[data.guest.name, data.guest.phone ? `+${data.guest.phone}` : null].filter(Boolean).join(" · ")}
              </div>
            )}
            {data.guest.address && <div>Deliver to: {data.guest.address}</div>}
          </div>
        )}
        {data.buyer && (
          <div className="mt-1 text-[1em]">
            Bill to: {data.buyer.name ?? ""}
            <br />
            {data.taxIdLabel}: {data.buyer.taxId}
          </div>
        )}

        <Rule />

        <table className="w-full text-[1em]">
          <thead>
            <tr className="text-left">
              <th className="font-semibold">Item</th>
              <th className="w-8 text-center font-semibold">Qty</th>
              {f.rate && <th className="w-12 text-right font-semibold">Rate</th>}
              <th className="w-16 text-right font-semibold">Amount</th>
            </tr>
          </thead>
          <tbody>
            {data.items.map((it, i) => (
              <tr key={i}>
                <td className="pr-1 align-top">
                  {it.name}
                  {it.local && <div className="text-[0.91em]">{it.local}</div>}
                  {it.options && <div className="text-[0.91em]">&nbsp;&nbsp;{it.options}</div>}
                  {it.offerName && (
                    <div className="text-[0.91em]">
                      &nbsp;&nbsp;{it.offerName}
                      {it.listPrice != null && it.listPrice > it.unitPrice ? ` (was ${it.listPrice.toFixed(2)})` : ""}
                    </div>
                  )}
                </td>
                <td className="text-center align-top">{it.unit ? `${it.qty.toFixed(3)} ${it.unit}` : it.qty}</td>
                {f.rate && <td className="text-right align-top">{it.unitPrice.toFixed(2)}</td>}
                <td className="text-right align-top">{m(it.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <Rule />

        <div className="space-y-0.5 text-[1em]">
          <Row label="Subtotal" value={m(data.subtotal)} />
          {data.discount > 0 && (
            <Row label={data.comp ? (data.comp.kind === "complimentary" ? "Complimentary" : "Staff meal") : "Discount"} value={`-${m(data.discount)}`} />
          )}
          {(data.loyaltyDiscount ?? 0) > 0 && <Row label="Loyalty points discount" value={`-${m(data.loyaltyDiscount ?? 0)}`} />}
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
        <div className="flex justify-between text-[1.27em] font-bold">
          <span>TOTAL</span>
          <span>{m(data.grandTotal)}</span>
        </div>

        {data.taxIncluded > 0 && !data.showVatBreakdown && (
          <div className="mt-1 space-y-0.5 text-[0.91em]" style={{ color: "#444" }}>
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
            <div className="space-y-0.5 text-[1em]">
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

        {loyaltyLines(data.loyalty).length > 0 && (
          <>
            <Rule />
            <div className="space-y-0.5 text-[1em]">
              {loyaltyLines(data.loyalty).map((x) => (
                <Row key={x.label} label={x.label} value={x.value} />
              ))}
            </div>
          </>
        )}

        {data.showVatBreakdown && (
          <>
            <Rule />
            <div className="space-y-0.5 text-[1em]">
              <Row label="VATable sales" value={m(vatable)} />
              {data.taxLines.length > 0 ? (
                data.taxLines.map((t, i) => <Row key={i} label={t.name} value={m(t.amount)} />)
              ) : (
                <Row label="VAT" value={m(data.taxTotal)} />
              )}
              <Row label="VAT-exempt sales" value={m(data.exemptSales)} />
              <Row label="Zero-rated sales" value={m(0)} />
            </div>
            {data.senior && (
              <div className="mt-2 text-[1em]">
                {data.senior.kind === "pwd" ? "PWD" : "Senior citizen"}: {data.senior.name}
                <br />
                ID no.: {data.senior.idNo}
                <div className="mt-3 border-t pt-0.5 text-center text-[0.91em]" style={{ borderColor: "#111" }}>
                  Signature
                </div>
              </div>
            )}
          </>
        )}

        {f.upi_qr && data.upi && (data.state === "unpaid" || data.state === "part-paid") && data.balance > 0 && (
          <>
            <Rule />
            <div className="flex justify-center py-1">
              <UpiQr upiId={data.upi.id} payee={data.upi.payee} amount={data.balance} note={`Bill ${data.billNumber}`} size={140} />
            </div>
          </>
        )}

        <Rule />
        <div className="text-center text-[1em]">{data.footer || "Thank you — visit again"}</div>
        {f.powered_by && (
          <div className="mt-1 text-center text-[0.91em]" style={{ color: "#666" }}>
            Billed on SNA POS
          </div>
        )}
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
