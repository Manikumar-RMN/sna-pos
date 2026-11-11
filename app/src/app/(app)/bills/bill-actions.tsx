"use client";

import Link from "next/link";
import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money, roundCash } from "@/lib/format";
import { parseDiscountInput } from "@/lib/discount";
import { UpiQr } from "../upi-qr";
import { Dual } from "../lang";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { KotSheet } from "../captain/kot-sheet";
import { useOnline } from "@/lib/use-online";
import { needsInternetText } from "@/lib/order-desk";
import { MoveItemPanel } from "./move-item-panel";
import { TipField } from "./tip-field";
import { tipError, tipForRequest } from "./tip";
import { reopenBill, adjustBill, makeComplimentary, cancelItem, changePaymentMode, fireHeld, issueCreditNote, setBillCustomer, mergeBills, moveTable, payBill, splitBill, voidBill } from "./actions";

type Method = { id: string; name: string; kind: string; ask_reference: boolean; upi_id?: string | null };
type PaymentRow = { id: string; methodId: string; methodName: string; amount: number; rounded: boolean };
type Line = { id: string; name: string; options: string | null; qty: number; amount: number };
type TableOpt = { id: string; number: string; busy: boolean };
type OtherBill = { id: string; billNumber: string; total: number; table: string | null; mergeable: boolean };
type Panel = null | "split" | "move" | "moveItem" | "merge" | "cancel" | "adjust" | "comp";
type Adjust = { discount: number; subtotal: number; scAvailable: boolean; scOn: boolean; scPercent: number; scLabel: string; senior: boolean };

export function BillActions({
  orderId,
  billNumber,
  state,
  grandTotal,
  balance,
  paidTotal,
  refunded,
  currency,
  methods,
  canPay,
  canVoid,
  canDiscount = false,
  canKots = false,
  adjust,
  discountPool,
  presets = [],
  loyaltyDiscount = 0,
  canChangeMode = false,
  dayClosed = false,
  heldCount = 0,
  buyer = null,
  taxIdLabel = "GSTIN",
  paymentList = [],
  upiPayee = null,
  canRefund,
  shiftOpen,
  cashRounding = "none",
  splitPay = false,
  lines,
  hasDiscount,
  hasPayments,
  tableId,
  tables,
  otherBills,
  canMerge = true,
  embedded = false,
}: {
  /** Total of the lines that can take a discount (lines marked "do not discount" are left out). Omit = the whole subtotal. */
  discountPool?: number;
  /** Saved discounts the owner set up (Settings → Discounts). A tap fills the amount and the reason. */
  presets?: { id: string; name: string; kind: "percent" | "amount"; value: number }[];
  /** Points already used as a discount on this bill (shown in the dialog; changed only in the loyalty panel). */
  loyaltyDiscount?: number;
  orderId: string;
  billNumber: string;
  state: "paid" | "unpaid" | "part-paid" | "voided" | "refunded" | "part-refunded";
  grandTotal: number;
  balance: number;
  paidTotal: number;
  refunded: number;
  currency: string;
  methods: Method[];
  canPay: boolean;
  canVoid: boolean;
  canDiscount?: boolean;
  /** Show "Sent KOTs": the bill is unpaid or part-paid, not voided, its day is open, and the user may take orders. */
  canKots?: boolean;
  adjust?: Adjust;
  canChangeMode?: boolean;
  /** The bill's day is closed: no void; money back only by credit note. */
  dayClosed?: boolean;
  heldCount?: number;
  /** B2B customer on the bill (India: GSTIN). Undefined hides the panel. */
  buyer?: { taxId: string; name: string | null } | null;
  taxIdLabel?: string;
  paymentList?: PaymentRow[];
  /** Name shown in the customer's UPI app (India). Null hides the QR. */
  upiPayee?: string | null;
  canRefund: boolean;
  shiftOpen: boolean;
  /** Cash-only rounding mode (e.g. Malaysia's 5 sen); "none" elsewhere. */
  cashRounding?: string;
  /** Opened from "Split payment" on the billing screen. */
  splitPay?: boolean;
  lines: Line[];
  hasDiscount: boolean;
  hasPayments: boolean;
  tableId: string | null;
  tables: TableOpt[];
  otherBills: OtherBill[];
  /** Professional: join two tables into one bill. */
  canMerge?: boolean;
  /** Shown inside the single order screen (/pos): "+ Add items" and a split go to that screen instead of the old pages. */
  embedded?: boolean;
}) {
  const router = useRouter();
  const online = useOnline();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const m = (n: number) => money(n, currency);

  const [methodId, setMethodId] = useState(methods[0]?.id ?? "");
  const [tendered, setTendered] = useState("");
  const [reference, setReference] = useState("");
  const [partAmt, setPartAmt] = useState("");
  const [refundAmt, setRefundAmt] = useState("");
  const [refundReason, setRefundReason] = useState("");
  const [voidReason, setVoidReason] = useState("");
  const [reopenReason, setReopenReason] = useState("");
  const [confirm, setConfirm] = useState<null | "void" | "refund" | "cancel">(null);
  const [panel, setPanel] = useState<Panel>(null);
  const [win, setWin] = useState<null | "pay" | "cancel" | "void" | "fix" | "refund" | "reopen">(null);
  const [showKots, setShowKots] = useState(false);
  const [moveTo, setMoveTo] = useState("");
  const [mergeFrom, setMergeFrom] = useState("");
  const [splitQty, setSplitQty] = useState<Record<string, number>>({});
  const [cancelId, setCancelId] = useState(lines[0]?.id ?? "");
  const [cancelQty, setCancelQty] = useState("1");
  const [cancelReason, setCancelReason] = useState("");
  const [discAmt, setDiscAmt] = useState(adjust && adjust.discount > 0 ? String(adjust.discount) : "");
  const [discReason, setDiscReason] = useState("");
  const [compKind, setCompKind] = useState<"complimentary" | "staff_meal">("complimentary");
  const [compReason, setCompReason] = useState("");
  const [scWanted, setScWanted] = useState<boolean>(adjust?.scOn ?? false);
  const [fixPay, setFixPay] = useState(paymentList.find((p) => !p.rounded)?.id ?? "");
  const [fixTo, setFixTo] = useState("");
  const [fixReason, setFixReason] = useState("");
  const [cnMethod, setCnMethod] = useState(paymentList[0]?.methodId ?? methods[0]?.id ?? "");
  const [approval, setApproval] = useState<null | { permission: string; retry: () => void }>(null);
  const [payRef, setPayRef] = useState(() => crypto.randomUUID());
  const [tip, setTip] = useState("");
  // Split and credit note: the same id while the same request is retried, a new one when
  // what is asked changes or after it is done. A repeat is answered once by the server.
  const splitRef = useRef<{ key: string; id: string } | null>(null);
  const creditRef = useRef<{ key: string; id: string } | null>(null);
  const [buyerId, setBuyerId] = useState(buyer?.taxId ?? "");
  const [buyerName, setBuyerName] = useState(buyer?.name ?? "");

  const open = state === "unpaid" || state === "part-paid";
  const remaining = Math.max(0, Math.round((paidTotal - refunded) * 100) / 100);
  const isCash = methods.find((x) => x.id === methodId)?.kind === "cash";
  const askRef = !!methods.find((x) => x.id === methodId)?.ask_reference;
  const part = partAmt.trim() === "" ? null : Math.round(Number(partAmt) * 100) / 100;
  const isFull = part === null || part >= balance;
  const due = isFull ? (isCash ? roundCash(balance, cashRounding) : balance) : part;
  const change = isCash && Number(tendered) > due ? Math.round((Number(tendered) - due) * 100) / 100 : 0;
  // Each person's share of the whole bill (not of what is left), so every payer is offered the same amount.
  const equalShare = (n: number) => Math.min(balance, Math.ceil(Math.round(grandTotal * 100) / n) / 100);

  const showPay = open && canPay;
  const upiMethod = methods.find((x) => x.id === methodId && x.kind === "upi" && x.upi_id);
  const fixable = paymentList.filter((p) => !p.rounded);
  const showFix = canChangeMode && state !== "voided" && fixable.length > 0;
  const fixRow = fixable.find((p) => p.id === fixPay) ?? fixable[0];
  const canAsk = canPay; // a cashier can ask a manager to approve with their PIN
  const showRefund = (canRefund || canAsk) && (state === "paid" || state === "part-refunded") && remaining > 0;
  const showReopen = (canVoid || canAsk) && (state === "paid" || state === "part-paid") && refunded === 0 && !dayClosed;
  const showVoid = (canVoid || canAsk) && state !== "voided" && refunded === 0 && !dayClosed;
  const cancelLine = lines.find((l) => l.id === cancelId) ?? lines[0];
  const splitCount = Object.values(splitQty).reduce((s, q) => s + q, 0);
  const splitBlocked = hasPayments
    ? "This bill already has a payment, so it cannot be split. Split the payment instead."
    : hasDiscount
      ? "This bill has a discount, so it cannot be split. Split the payment instead."
      : lines.length < 2 && (lines[0]?.qty ?? 0) < 2
        ? "There is only one item on this bill."
        : null;
  const mergeable = otherBills.filter((b) => b.mergeable);
  // "10%" is turned into an amount on the bill's subtotal; the server only takes the amount.
  // A percent is worked out on the lines that can be discounted, not on the whole subtotal.
  const pool = Math.max(0, discountPool ?? adjust?.subtotal ?? 0);
  const someBlocked = !!adjust && pool < adjust.subtotal - 0.004;
  const noPool = !!adjust && pool <= 0;
  const discParsed = parseDiscountInput(discAmt, pool);
  const discNum = discParsed.ok ? discParsed.amount : 0;
  const showAdjust =
    !!adjust && state === "unpaid" && !hasPayments && (canPay || canDiscount);
  const adjustChanged = !!adjust && (discNum !== adjust.discount || (adjust.scAvailable && scWanted !== adjust.scOn));

  function run(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) {
    setError(null);
    setNotice(null);
    start(async () => {
      const res = await fn();
      if (!res.ok) {
        const need = neededRight(res.error);
        if (need) setApproval({ permission: need, retry: () => run(fn, after) });
        setError(cleanMessage(res.error ?? "Something went wrong."));
        return;
      }
      setNotice(res.message ?? "Done.");
      if (res.message?.startsWith("Paid in full")) {
        const url = new URL(window.location.href);
        url.searchParams.set("print", "1");
        window.history.replaceState(null, "", url.toString());
      }
      setConfirm(null);
      setPanel(null);
      setWin(null);
      setVoidReason("");
      setReopenReason("");
      setRefundReason("");
      setRefundAmt("");
      setTendered("");
      setReference("");
      setPartAmt("");
      setCancelReason("");
      setSplitQty({});
      after?.();
      router.refresh();
    });
  }

  const showBuyer = buyer !== undefined && state !== "voided" && !dayClosed && (canPay || canVoid);
  const showFire = open && heldCount > 0 && !dayClosed;
  if (!showPay && !showRefund && !showVoid && !showFix && !showBuyer && !showFire && !canKots && !notice) return null;

  return (
    <div className="no-print mx-auto mt-4 max-w-sm space-y-3">
      {approval && (
        <ApprovalPrompt
          permission={approval.permission}
          onCancel={() => setApproval(null)}
          onApproved={(who) => {
            const retry = approval.retry;
            setApproval(null);
            setNotice(`Approved by ${who}.`);
            retry();
          }}
        />
      )}
      {dayClosed && state !== "voided" && (
        <p className="rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-ground)", color: "var(--color-ink-2)" }}>
          This bill&rsquo;s day is closed, so it cannot be voided or changed. Money back is given with a credit note dated today.
        </p>
      )}
      {notice && (
        <p className="rounded-lg px-3 py-2 text-sm" role="status" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}>
          {notice}
        </p>
      )}
      {error && (
        <p className="rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {error}
        </p>
      )}

      {!online && (
        <p className="rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
          {needsInternetText("bill_action")}
        </p>
      )}

      {showFire && (
        <button className="btn btn-pay w-full text-sm" disabled={pending} onClick={() => run(() => fireHeld(orderId))}>
          {pending ? "Sending…" : `Send ${heldCount} held item${heldCount === 1 ? "" : "s"} to the kitchen (next course)`}
        </button>
      )}

      {canKots && (
        <button className="btn w-full border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setShowKots(true)}>
          Sent KOTs
        </button>
      )}
      {canKots && showKots && <KotSheet orderId={orderId} billNumber={billNumber} onClose={() => setShowKots(false)} onChanged={() => router.refresh()} />}

      {embedded && !showPay && showReopen && (
        <button type="button" className="btn w-full border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setWin("reopen")}>
          Cancel settlement…
        </button>
      )}

      {embedded && !showPay && (showFix || showRefund) && (
        <div className="grid grid-cols-2 gap-2">
          {showFix && <PanelButton label="Change payment mode" active={win === "fix"} onClick={() => setWin("fix")} />}
          {showRefund && <PanelButton label="Refund / credit note" active={win === "refund"} onClick={() => setWin("refund")} />}
        </div>
      )}

      {embedded && !showPay && showVoid && (
        <button type="button" className="btn w-full border text-sm" style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }} onClick={() => setWin("void")}>
          Void bill…
        </button>
      )}

      {showPay && (!embedded || win === "pay") && (
        <PanelFrame modal={embedded} title="Take payment" error={error} notice={notice} onClose={() => setWin(null)}>
        <section className="card p-4">
          <div className="flex items-baseline justify-between">
            <h2 className="text-sm font-bold">Take payment</h2>
            <span className="text-sm">
              {state === "part-paid" ? "Balance " : "To pay "}
              <b>{m(balance)}</b>
            </span>
          </div>
          {!shiftOpen ? (
            <p className="mt-2 text-sm" style={{ color: "var(--color-ink-2)" }}>
              Open a shift on the Shift screen before taking payments.
            </p>
          ) : (
            <>
              {splitPay && state === "unpaid" && (
                <p className="mt-2 rounded-md px-2.5 py-1.5 text-xs" style={{ background: "var(--color-brand-soft)" }}>
                  Take each part one at a time: choose how that part is paid, enter its amount, and press Take. Repeat until the balance is zero.
                </p>
              )}
              <div className="mt-3 grid grid-cols-3 gap-1.5">
                {methods.map((x) => (
                  <button
                    key={x.id}
                    onClick={() => setMethodId(x.id)}
                    className="rounded-lg border px-2 py-2 text-xs font-semibold"
                    style={{
                      borderColor: methodId === x.id ? "var(--color-brand)" : "var(--color-line)",
                      background: methodId === x.id ? "var(--color-brand-soft)" : "transparent",
                      color: methodId === x.id ? "var(--color-brand-strong)" : "var(--color-ink-2)",
                    }}
                  >
                    {x.name}
                  </button>
                ))}
              </div>

              <label className="mt-3 block text-xs font-medium" style={{ color: "var(--color-ink-2)" }} htmlFor="part-amt">
                Amount for this payment
              </label>
              <input
                id="part-amt"
                className="field mt-1 h-10 text-sm"
                inputMode="decimal"
                placeholder={`Full balance ${balance.toFixed(2)}`}
                value={partAmt}
                onChange={(e) => setPartAmt(e.target.value)}
              />
              <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs">
                <span style={{ color: "var(--color-ink-3)" }}>Share equally:</span>
                {[2, 3, 4, 5].map((n) => (
                  <button
                    key={n}
                    className="rounded-md border px-2 py-1 font-semibold"
                    style={{ borderColor: "var(--color-line)" }}
                    onClick={() => setPartAmt(equalShare(n).toFixed(2))}
                    aria-label={`Split between ${n} people`}
                  >
                    ÷{n}
                  </button>
                ))}
                {partAmt !== "" && (
                  <button className="rounded-md px-2 py-1 font-semibold" style={{ color: "var(--color-brand-strong)" }} onClick={() => setPartAmt("")}>
                    Full balance
                  </button>
                )}
              </div>

              {upiMethod?.upi_id && upiPayee && due > 0 && (
                <div className="mt-3 rounded-lg border p-3" style={{ borderColor: "var(--color-line)", background: "#fff" }}>
                  <UpiQr upiId={upiMethod.upi_id} payee={upiPayee} amount={due} note={`Bill ${billNumber}`} />
                </div>
              )}
              {askRef && !isCash && (
                <input
                  className="field mt-2 h-10 text-sm"
                  placeholder="Reference, e.g. UPI txn ID or card last 4 (optional)"
                  value={reference}
                  maxLength={60}
                  onChange={(e) => setReference(e.target.value)}
                />
              )}
              {isCash && (
                <div className="mt-2 flex items-center gap-2">
                  <input className="field h-10 flex-1 text-sm" inputMode="decimal" placeholder="Cash received" value={tendered} onChange={(e) => setTendered(e.target.value)} />
                  <span className="text-sm">
                    Change <b>{m(change)}</b>
                  </span>
                </div>
              )}
              {isCash && due > 0 && (
                <div className="mt-1.5 flex flex-wrap items-center gap-1.5 text-xs" role="group" aria-label="Cash received quick amounts">
                  <button className="rounded-md border px-2 py-1 font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setTendered(due.toFixed(2))}>
                    Exact {m(due)}
                  </button>
                  {Array.from(new Set([10, 50, 100, 500, 1000].map((step) => Math.ceil(due / step) * step))).filter((v) => v > due).slice(0, 4).map((v) => (
                    <button key={v} className="rounded-md border px-2 py-1 font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setTendered(String(v))}>
                      {m(v)}
                    </button>
                  ))}
                </div>
              )}
              {/* A tip is a memo for the report: it is not part of "Take ..." or of the change. */}
              <TipField value={tip} onChange={setTip} base={due} disabled={pending} offline={!online} />
              <button
                className="btn btn-pay mt-3 w-full text-base"
                disabled={pending || !methodId || (part !== null && !(part > 0)) || (part !== null && part > balance) || (isCash && tendered !== "" && Number(tendered) < due) || (online && tipError(tip) !== null)}
                onClick={() =>
                  run(() =>
                    payBill({
                      orderId,
                      paymentMethodId: methodId,
                      tendered: isCash && tendered !== "" ? Number(tendered) : null,
                      amount: isFull ? null : part,
                      reference: askRef && !isCash ? reference : null,
                      clientRef: payRef,
                      tip: online ? tipForRequest(tip) : undefined,
                    }),
                    () => {
                      setPayRef(crypto.randomUUID());
                      setTip("");
                    },
                  )
                }
              >
                {pending ? "Saving…" : part !== null && part > balance ? `Only ${m(balance)} is left` : `Take ${m(due)}${isFull ? "" : " (part)"}`}
              </button>
            </>
          )}
        </section>
        </PanelFrame>
      )}

      {showPay && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Table &amp; items</h2>

          <div className="mt-3 grid grid-cols-2 gap-2">
            {embedded ? (
              <button
                type="button"
                className="btn btn-primary text-sm"
                disabled={!online}
                title={online ? undefined : needsInternetText("add_to_bill")}
                onClick={() => window.dispatchEvent(new Event("sna-desk-order"))}
              >
                + Add items
              </button>
            ) : (
              <Link href={`/pos?add=${orderId}`} className="btn btn-primary text-sm">
                + Add items
              </Link>
            )}
            {embedded && (
              <button type="button" className="btn btn-pay col-span-2 text-sm" onClick={() => setWin("pay")}>
                Settle · {m(balance)}
              </button>
            )}
            <PanelButton label="Split bill" active={panel === "split"} onClick={() => setPanel(panel === "split" ? null : "split")} />
            <PanelButton label="Move table" active={panel === "move"} onClick={() => setPanel(panel === "move" ? null : "move")} />
            <PanelButton
              label="Move item"
              active={panel === "moveItem"}
              disabled={!online}
              title={online ? undefined : needsInternetText("move_item")}
              onClick={() => setPanel(panel === "moveItem" ? null : "moveItem")}
            />
            {canMerge && <PanelButton label="Merge bills" active={panel === "merge"} onClick={() => setPanel(panel === "merge" ? null : "merge")} />}
            {showAdjust && (
              <PanelButton
                label={adjust?.scAvailable ? "Discount / service" : "Discount"}
                active={panel === "adjust"}
                onClick={() => setPanel(panel === "adjust" ? null : "adjust")}
              />
            )}
            {embedded && open && (canVoid || canAsk) && lines.length > 0 && !dayClosed && (
              <PanelButton label="Cancel item" active={win === "cancel"} onClick={() => setWin("cancel")} />
            )}
            {embedded && showVoid && <PanelButton label="Void bill" active={win === "void"} onClick={() => setWin("void")} />}
            {showAdjust && !adjust?.senior && (
              <PanelButton label="Complimentary / staff meal" active={panel === "comp"} onClick={() => setPanel(panel === "comp" ? null : "comp")} />
            )}
          </div>

          {!online && (
            <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
              {needsInternetText("add_to_bill")} {needsInternetText("move_item")}
            </p>
          )}

          <PanelFrame
            modal={embedded && panel !== null}
            title={panel === "comp" ? "Complimentary / staff meal" : panel === "adjust" ? "Discount" : panel === "split" ? "Split bill" : panel === "move" ? "Move table" : panel === "moveItem" ? "Move item" : "Merge bills"}
            error={error}
            notice={notice}
            onClose={() => setPanel(null)}
          >
          {panel === "comp" && (
            <div className="mt-3 space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                The whole bill ({m(grandTotal)}) is taken off and the bill closes at 0.00. It shows on the reports as{" "}
                {compKind === "complimentary" ? "complimentary" : "a staff meal"}, not as a discount.
                {!canDiscount ? " A manager approves it with their PIN." : ""}
              </p>
              <div className="grid grid-cols-2 gap-2" role="radiogroup" aria-label="Kind">
                {(["complimentary", "staff_meal"] as const).map((k) => (
                  <button
                    key={k}
                    role="radio"
                    aria-checked={compKind === k}
                    className="btn border text-sm"
                    style={{ borderColor: compKind === k ? "var(--color-brand)" : "var(--color-line)", background: compKind === k ? "var(--color-brand-soft)" : undefined }}
                    onClick={() => setCompKind(k)}
                  >
                    {k === "complimentary" ? "Complimentary" : "Staff meal"}
                  </button>
                ))}
              </div>
              <input
                className="field h-10 text-sm"
                placeholder={compKind === "complimentary" ? "Reason, e.g. guest name / owner's guest" : "Staff member's name"}
                aria-label="Reason"
                value={compReason}
                onChange={(e) => setCompReason(e.target.value)}
                maxLength={200}
              />
              <button
                className="btn btn-primary mt-1 w-full text-sm"
                disabled={pending || compReason.trim().length < 3}
                onClick={() => run(() => makeComplimentary({ orderId, kind: compKind, reason: compReason }), () => setCompReason(""))}
              >
                {pending ? "Saving…" : compKind === "complimentary" ? "Make complimentary" : "Make staff meal"}
              </button>
              {compReason.trim().length < 3 && (
                <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {compKind === "complimentary" ? "Type a reason (at least 3 letters) to continue." : "Type the staff member's name (at least 3 letters) to continue."}
                </p>
              )}
            </div>
          )}

          {panel === "adjust" && adjust && (
            <div className="mt-3 space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              {adjust.scAvailable && (
                <label className="flex items-center justify-between text-sm">
                  <span>
                    {adjust.scLabel} {adjust.scPercent}%
                  </span>
                  <input type="checkbox" className="h-5 w-5" checked={scWanted} onChange={(e) => setScWanted(e.target.checked)} aria-label={`${adjust.scLabel} on this bill`} />
                </label>
              )}
              {adjust.senior ? (
                <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  This bill has a senior citizen / PWD discount, so no other discount can be added.
                </p>
              ) : canDiscount || canPay ? (
                <>
                  {!canDiscount && (
                    <p className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                      A manager approves discounts with their PIN.
                    </p>
                  )}
                  <label className="block text-xs font-medium" style={{ color: "var(--color-ink-2)" }} htmlFor="adj-disc">
                    Discount (amount or %)
                  </label>
                  {presets.length > 0 && !noPool && (
                    <div className="flex flex-wrap gap-1.5" role="group" aria-label="Saved discounts">
                      {presets.map((x) => (
                        <button
                          key={x.id}
                          type="button"
                          className="tap rounded-full border px-3 py-1.5 text-xs font-medium"
                          style={{ borderColor: "var(--color-line)", background: discReason === x.name ? "var(--color-brand-soft, #e6f2ec)" : "transparent" }}
                          onClick={() => {
                            setDiscAmt(x.kind === "percent" ? `${x.value}%` : String(x.value));
                            setDiscReason(x.name);
                          }}
                        >
                          {x.name} {x.kind === "percent" ? `${x.value}%` : m(x.value)}
                        </button>
                      ))}
                    </div>
                  )}
                  <input
                    id="adj-disc"
                    className="field h-10 text-sm"
                    inputMode="text"
                    placeholder={noPool ? "None of these items can be discounted" : "Amount or percent, e.g. 10%"}
                    value={discAmt}
                    disabled={noPool}
                    onChange={(e) => setDiscAmt(e.target.value)}
                  />
                  {noPool ? (
                    <p className="text-xs" role="status" style={{ color: "var(--color-ink-3)" }}>
                      None of these items can be discounted.
                    </p>
                  ) : (
                    someBlocked && (
                      <p className="text-xs" role="status" style={{ color: "var(--color-ink-3)" }} data-testid="discount-pool-note">
                        Discount applies to {m(pool)} of {m(adjust.subtotal)}. Some items cannot be discounted.
                      </p>
                    )
                  )}
                  {loyaltyDiscount > 0 && (
                    <p className="text-xs" role="status" style={{ color: "var(--color-ink-3)" }}>
                      Loyalty points already take {m(loyaltyDiscount)} off this bill.
                    </p>
                  )}
                  {!discParsed.ok && (
                    <p className="text-xs" role="alert" style={{ color: "var(--color-bad)" }}>
                      {discParsed.message}
                    </p>
                  )}
                  {discParsed.ok && discParsed.percent !== null && (
                    <p className="text-xs" role="status" style={{ color: "var(--color-ink-2)" }}>
                      {discParsed.percent}% = {m(discParsed.amount)}
                    </p>
                  )}
                  {discNum > 0 && (
                    <input className="field h-10 text-sm" placeholder="Reason (optional)" value={discReason} onChange={(e) => setDiscReason(e.target.value)} maxLength={200} />
                  )}
                </>
              ) : (
                <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  A manager gives discounts{adjust.scAvailable ? " and removes the service charge" : ""}.
                </p>
              )}
              <button
                className="btn btn-primary mt-1 w-full text-sm"
                disabled={pending || !adjustChanged || !discParsed.ok || (noPool && discNum > 0)}
                onClick={() =>
                  run(() =>
                    adjustBill({
                      orderId,
                      discount: discNum,
                      reason: discReason || null,
                      serviceCharge: adjust.scAvailable ? scWanted : null,
                    }),
                  )
                }
              >
                {pending ? "Saving…" : "Update bill"}
              </button>
            </div>
          )}

          {panel === "split" && (
            <div className="mt-3 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              {splitBlocked ? (
                <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                  {splitBlocked}
                </p>
              ) : (
                <>
                  <p className="mb-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                    Choose what moves to a new bill. Tax and totals are worked out again for both bills.
                  </p>
                  <ul className="space-y-1.5">
                    {lines.map((l) => {
                      const q = splitQty[l.id] ?? 0;
                      return (
                        <li key={l.id} className="flex items-center gap-2 text-sm">
                          <div className="min-w-0 flex-1">
                            <div className="truncate">{l.name}</div>
                            {l.options && (
                              <div className="truncate text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                                {l.options}
                              </div>
                            )}
                          </div>
                          <Stepper
                            value={q}
                            max={l.qty}
                            label={l.name}
                            onChange={(v) => setSplitQty({ ...splitQty, [l.id]: v })}
                          />
                          <span className="w-8 text-right text-xs" style={{ color: "var(--color-ink-3)" }}>
                            of {l.qty}
                          </span>
                        </li>
                      );
                    })}
                  </ul>
                  <button
                    className="btn btn-primary mt-3 w-full text-sm"
                    disabled={pending || splitCount === 0 || splitCount >= lines.reduce((s, l) => s + l.qty, 0)}
                    onClick={() => {
                      setError(null);
                      const items = Object.entries(splitQty)
                        .filter(([, qty]) => qty > 0)
                        .map(([order_item_id, qty]) => ({ order_item_id, qty }))
                        .sort((a, b) => a.order_item_id.localeCompare(b.order_item_id));
                      const key = JSON.stringify(items);
                      if (splitRef.current?.key !== key) splitRef.current = { key, id: crypto.randomUUID() };
                      const clientRef = splitRef.current.id;
                      start(async () => {
                        let res: Awaited<ReturnType<typeof splitBill>>;
                        try {
                          res = await splitBill({ orderId, items, clientRef });
                        } catch {
                          // No reply from the server. The same request id makes pressing the button again safe.
                          return setError("The internet dropped while splitting. Press the button again — the bill will not be split twice.");
                        }
                        if (!res.ok) return setError(res.error);
                        splitRef.current = null;
                        router.push(embedded ? `/pos?bill=${res.newOrderId}` : `/bills/${res.newOrderId}`);
                      });
                    }}
                  >
                    {pending ? "Splitting…" : `Move ${splitCount || ""} to a new bill`}
                  </button>
                </>
              )}
            </div>
          )}

          {panel === "move" && (
            <div className="mt-3 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              {tables.length === 0 ? (
                <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                  No tables are set up. Add tables in Settings.
                </p>
              ) : (
                <>
                  <div className="flex flex-wrap gap-1.5">
                    {tables
                      .filter((t) => t.id !== tableId)
                      .map((t) => (
                        <button
                          key={t.id}
                          onClick={() => setMoveTo(t.id)}
                          disabled={t.busy}
                          className="rounded-md border px-2.5 py-1 text-xs font-semibold disabled:opacity-40"
                          aria-label={t.busy ? `T${t.number}, has an open bill` : `T${t.number}`}
                          style={{
                            borderColor: moveTo === t.id ? "var(--color-brand)" : "var(--color-line)",
                            background: moveTo === t.id ? "var(--color-brand)" : "transparent",
                            color: moveTo === t.id ? "#fff" : "var(--color-ink-2)",
                          }}
                        >
                          T{t.number}
                        </button>
                      ))}
                  </div>
                  <p className="mt-1.5 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    Faded tables already have an open bill — use Merge bills for those.
                  </p>
                  <button className="btn btn-primary mt-3 w-full text-sm" disabled={pending || !moveTo} onClick={() => run(() => moveTable({ orderId, tableId: moveTo }))}>
                    {pending ? "Moving…" : "Move this bill"}
                  </button>
                </>
              )}
            </div>
          )}

          {panel === "moveItem" && online && (
            <div className="mt-3 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              <MoveItemPanel
                orderId={orderId}
                billNumber={billNumber}
                lines={lines}
                tables={tables}
                currentTableId={tableId}
                blocked={
                  hasPayments
                    ? "This bill already has a payment, so items cannot be moved off it. Split the payment instead."
                    : hasDiscount
                      ? "This bill has a discount, so items cannot be moved. Remove the discount first or split the payment."
                      : null
                }
                onMoved={() => {
                  setPanel(null);
                  router.refresh();
                }}
              />
            </div>
          )}

          {panel === "merge" && (
            <div className="mt-3 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              {mergeable.length === 0 ? (
                <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                  No other open bill can be merged. Bills with a payment or a discount cannot be merged.
                </p>
              ) : (
                <>
                  <p className="mb-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                    The chosen bill&rsquo;s items move onto bill {billNumber}. The other bill is closed, marked &ldquo;Merged&rdquo;.
                  </p>
                  <ul className="space-y-1.5">
                    {mergeable.map((b) => (
                      <li key={b.id}>
                        <label className="flex items-center gap-2 text-sm">
                          <input type="radio" name="merge" checked={mergeFrom === b.id} onChange={() => setMergeFrom(b.id)} />
                          <span className="flex-1">
                            Bill {b.billNumber}
                            {b.table ? ` · T${b.table}` : ""}
                          </span>
                          <span className="font-semibold">{m(b.total)}</span>
                        </label>
                      </li>
                    ))}
                  </ul>
                  <button
                    className="btn btn-primary mt-3 w-full text-sm"
                    disabled={pending || !mergeFrom}
                    onClick={() => run(() => mergeBills({ targetId: orderId, sourceId: mergeFrom }), () => setMergeFrom(""))}
                  >
                    {pending ? "Merging…" : "Merge into this bill"}
                  </button>
                  {!mergeFrom && (
                    <p className="mt-1.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
                      Choose the bill to merge, above.
                    </p>
                  )}
                </>
              )}
            </div>
          )}
          </PanelFrame>
        </section>
      )}

      {open && (canVoid || canAsk) && lines.length > 0 && !dayClosed && (!embedded || win === "cancel") && (
        <PanelFrame modal={embedded} title="Cancel item" error={error} notice={notice} onClose={() => setWin(null)}>
        <section className="card p-4">
          <h2 className="text-sm font-bold"><Dual text="Cancel an item" /></h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Takes an item off this bill and tells the kitchen. Recorded with your name and reason.
          </p>
          <select className="field mt-3 h-10 text-sm" value={cancelLine?.id ?? ""} onChange={(e) => { setCancelId(e.target.value); setCancelQty("1"); }} aria-label="Item to cancel">
            {lines.map((l) => (
              <option key={l.id} value={l.id}>
                {l.qty} × {l.name}
                {l.options ? ` (${l.options})` : ""}
              </option>
            ))}
          </select>
          <div className="mt-2 flex gap-2">
            <input className="field h-10 w-20 shrink-0 text-center text-sm" inputMode="numeric" value={cancelQty} onChange={(e) => setCancelQty(e.target.value)} aria-label="How many to cancel" />
            <input className="field h-10 min-w-0 flex-1 text-sm" placeholder="Reason (required)" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} />
          </div>
          {confirm === "cancel" ? (
            <div className="mt-3 flex gap-2">
              <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirm(null)}>
                Keep it
              </button>
              <button
                className="btn flex-1 text-sm text-white"
                style={{ background: "var(--color-bad)" }}
                disabled={pending}
                onClick={() => run(() => cancelItem({ orderId, itemId: cancelLine?.id ?? "", qty: Number(cancelQty), reason: cancelReason }), () => { setCancelId(""); setCancelQty("1"); })}
              >
                {pending ? "Saving…" : `Cancel ${cancelQty} × ${cancelLine?.name ?? ""}`}
              </button>
            </div>
          ) : (
            <button
              className="btn mt-3 w-full border text-sm"
              style={{ borderColor: "var(--color-line)" }}
              disabled={!cancelLine || !Number.isInteger(Number(cancelQty)) || !(Number(cancelQty) > 0) || Number(cancelQty) > (cancelLine?.qty ?? 0) || cancelReason.trim().length < 3}
              onClick={() => setConfirm("cancel")}
            >
              Cancel item…
            </button>
          )}
        </section>
        </PanelFrame>
      )}

      {showBuyer && (
        <details className="card p-4" open={!!buyer}>
          <summary className="cursor-pointer text-sm font-bold">Business customer ({taxIdLabel} on the bill)</summary>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            For a company that wants to claim the tax back. Printed on the bill and listed in the GST register.
          </p>
          <input
            className="field mt-3 h-10 text-sm uppercase"
            placeholder={`${taxIdLabel}, e.g. 33AAACA0000A1Z5`}
            maxLength={15}
            value={buyerId}
            onChange={(e) => setBuyerId(e.target.value.toUpperCase())}
          />
          <input className="field mt-2 h-10 text-sm" placeholder="Business name" maxLength={120} value={buyerName} onChange={(e) => setBuyerName(e.target.value)} />
          <button
            className="btn mt-3 w-full border text-sm"
            style={{ borderColor: "var(--color-line)" }}
            disabled={pending || (buyerId.trim() !== "" && buyerName.trim() === "")}
            onClick={() => run(() => setBillCustomer({ orderId, taxId: buyerId, name: buyerName }))}
          >
            {pending ? "Saving…" : buyer && !buyerId.trim() ? "Remove from bill" : "Save on bill"}
          </button>
        </details>
      )}

      {showFix && fixRow && (!embedded || win === "fix") && (
        <PanelFrame modal={embedded} title="Change payment mode" error={error} notice={notice} onClose={() => setWin(null)}>
        <section className="card p-4">
          <h2 className="text-sm font-bold">Change payment mode</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            For a wrong button press, e.g. Cash was pressed but the customer paid by UPI. Allowed while the shift is open;
            recorded with your name and reason.
          </p>
          {fixable.length > 1 && (
            <select className="field mt-3 h-10 text-sm" value={fixRow.id} onChange={(e) => setFixPay(e.target.value)} aria-label="Payment to change">
              {fixable.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.methodName} {m(p.amount)}
                </option>
              ))}
            </select>
          )}
          <div className="mt-3 grid grid-cols-3 gap-1.5">
            {methods
              .filter((x) => x.id !== fixRow.methodId)
              .map((x) => (
                <button
                  key={x.id}
                  onClick={() => setFixTo(x.id)}
                  className="rounded-lg border px-2 py-2 text-xs font-semibold"
                  style={{
                    borderColor: fixTo === x.id ? "var(--color-brand)" : "var(--color-line)",
                    background: fixTo === x.id ? "var(--color-brand-soft)" : "transparent",
                  }}
                >
                  {x.name}
                </button>
              ))}
          </div>
          <input className="field mt-2 h-10 text-sm" placeholder="Reason (required)" value={fixReason} onChange={(e) => setFixReason(e.target.value)} />
          <button
            className="btn mt-3 w-full border text-sm"
            style={{ borderColor: "var(--color-line)" }}
            disabled={pending || !fixTo || fixReason.trim().length < 3}
            onClick={() =>
              run(
                () => changePaymentMode({ orderId, paymentId: fixRow.id, methodId: fixTo, reason: fixReason }),
                () => {
                  setFixTo("");
                  setFixReason("");
                },
              )
            }
          >
            {pending ? "Saving…" : `Change ${fixRow.methodName} ${m(fixRow.amount)} to ${methods.find((x) => x.id === fixTo)?.name ?? "…"}`}
          </button>
        </section>
        </PanelFrame>
      )}

      {showRefund && (!embedded || win === "refund") && (
        <PanelFrame modal={embedded} title="Refund / credit note" error={error} notice={notice} onClose={() => setWin(null)}>
        <section className="card p-4">
          <h2 className="text-sm font-bold">Refund (credit note)</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Up to {m(remaining)} can be given back. A credit note dated today is made with its own number; the bill stays as it was.
          </p>
          <div className="mt-3 text-xs font-medium" style={{ color: "var(--color-ink-2)" }}>
            Money given back by
          </div>
          <div className="mt-1.5 grid grid-cols-3 gap-1.5">
            {methods.map((x) => (
              <button
                key={x.id}
                onClick={() => setCnMethod(x.id)}
                className="rounded-lg border px-2 py-2 text-xs font-semibold"
                style={{
                  borderColor: cnMethod === x.id ? "var(--color-brand)" : "var(--color-line)",
                  background: cnMethod === x.id ? "var(--color-brand-soft)" : "transparent",
                }}
              >
                {x.name}
              </button>
            ))}
          </div>
          <input
            className="field mt-3 h-10 text-sm"
            inputMode="decimal"
            placeholder={`Amount (max ${remaining.toFixed(2)})`}
            value={refundAmt}
            onChange={(e) => setRefundAmt(e.target.value)}
          />
          <input className="field mt-2 h-10 text-sm" placeholder="Reason (required)" value={refundReason} onChange={(e) => setRefundReason(e.target.value)} />
          {confirm === "refund" ? (
            <div className="mt-3 flex gap-2">
              <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirm(null)}>
                Cancel
              </button>
              <button
                className="btn flex-1 text-sm text-white"
                style={{ background: "var(--color-bad)" }}
                disabled={pending}
                onClick={() => {
                  const input = { orderId, amount: Number(refundAmt), methodId: cnMethod, reason: refundReason.trim() };
                  const key = JSON.stringify(input);
                  if (creditRef.current?.key !== key) creditRef.current = { key, id: crypto.randomUUID() };
                  const clientRef = creditRef.current.id;
                  run(
                    async () => {
                      try {
                        return await issueCreditNote({ ...input, clientRef });
                      } catch {
                        // No reply from the server. The same request id makes pressing the button again safe.
                        return { ok: false, error: "The internet dropped while saving. Press the button again — the credit note will not be made twice." };
                      }
                    },
                    () => {
                      creditRef.current = null;
                    },
                  );
                }}
              >
                {pending ? "Saving…" : `Make credit note ${m(Number(refundAmt) || 0)}`}
              </button>
            </div>
          ) : (
            <button
              className="btn mt-3 w-full border text-sm"
              style={{ borderColor: "var(--color-line)" }}
              disabled={!(Number(refundAmt) > 0) || Number(refundAmt) > remaining || refundReason.trim().length < 3 || !cnMethod}
              onClick={() => setConfirm("refund")}
            >
              Refund…
            </button>
          )}
        </section>
        </PanelFrame>
      )}

      {showVoid && (!embedded || win === "void") && (
        <PanelFrame modal={embedded} title="Void bill" error={error} notice={notice} onClose={() => setWin(null)}>
        <section className="card p-4">
          <h2 className="text-sm font-bold">Void bill</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Cancels the whole bill. It stays visible in reports, marked Voided, with your name and reason.
            {paidTotal > 0 ? " Any money taken is treated as returned to the customer." : ""}
          </p>
          <input className="field mt-3 h-10 text-sm" placeholder="Reason (required)" value={voidReason} onChange={(e) => setVoidReason(e.target.value)} />
          {confirm === "void" ? (
            <div className="mt-3 flex gap-2">
              <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirm(null)}>
                Cancel
              </button>
              <button
                className="btn flex-1 text-sm text-white"
                style={{ background: "var(--color-bad)" }}
                disabled={pending}
                onClick={() => run(() => voidBill({ orderId, reason: voidReason }))}
              >
                {pending ? "Saving…" : "Confirm void"}
              </button>
            </div>
          ) : (
            <button
              className="btn mt-3 w-full border text-sm"
              style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }}
              disabled={voidReason.trim().length < 3}
              onClick={() => setConfirm("void")}
            >
              Void…
            </button>
          )}
        </section>
        </PanelFrame>
      )}
      {showReopen && (!embedded || win === "reopen") && (
        <PanelFrame modal={embedded} title="Cancel settlement" error={error} notice={notice} onClose={() => setWin(null)}>
          <section className="card p-4">
            <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
              The payment is taken off and the bill is open again, so it can be settled again (for example with the right payment mode). Recorded with your name and reason.
              Only for bills paid by cash, UPI or card in the shift that is still open. After that, void the bill or use a credit note.
            </p>
            <input className="field mt-3 h-10 min-w-0 text-sm" placeholder="Reason (required)" value={reopenReason} onChange={(e) => setReopenReason(e.target.value)} />
            <button
              className="btn mt-3 w-full text-sm text-white"
              style={{ background: "var(--color-bad)" }}
              disabled={pending || reopenReason.trim().length < 3}
              onClick={() => run(() => reopenBill({ orderId, reason: reopenReason }))}
            >
              {pending ? "Saving…" : "Cancel settlement"}
            </button>
          </section>
        </PanelFrame>
      )}
    </div>
  );
}

/** On the single order screen the opened panel shows in a medium window; elsewhere it stays inline. */
function PanelFrame({ modal, title, error, notice, onClose, children }: { modal: boolean; title: string; error: string | null; notice: string | null; onClose: () => void; children: React.ReactNode }) {
  if (!modal) return <>{children}</>;
  return (
    <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" role="dialog" aria-modal="true" aria-label={title} onClick={onClose}>
      <div className="card max-h-[85vh] w-full max-w-md overflow-y-auto p-4" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between">
          <h2 className="text-base font-bold">{title}</h2>
          <button type="button" className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={onClose} aria-label="Close">
            ✕
          </button>
        </div>
        {error && (
          <p className="mt-2 rounded-md p-2 text-sm" style={{ color: "var(--color-bad)" }}>
            {error}
          </p>
        )}
        {notice && !error && <p className="mt-2 text-sm">{notice}</p>}
        {children}
      </div>
    </div>
  );
}

function PanelButton({ label, active, onClick, disabled = false, title }: { label: string; active: boolean; onClick: () => void; disabled?: boolean; title?: string }) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      aria-expanded={active}
      className="btn border text-sm"
      style={{
        borderColor: active ? "var(--color-brand)" : "var(--color-line)",
        background: active ? "var(--color-brand-soft)" : "var(--color-surface)",
      }}
    >
      <Dual text={label} />
    </button>
  );
}

function Stepper({ value, max, label, onChange }: { value: number; max: number; label: string; onChange: (v: number) => void }) {
  return (
    <div className="flex items-center gap-1">
      <button
        className="grid h-8 w-8 place-items-center rounded-md border"
        style={{ borderColor: "var(--color-line)" }}
        onClick={() => onChange(Math.max(0, value - 1))}
        disabled={value <= 0}
        aria-label={`One less ${label} to move`}
      >
        −
      </button>
      <span className="w-5 text-center text-sm font-semibold">{value}</span>
      <button
        className="grid h-8 w-8 place-items-center rounded-md border"
        style={{ borderColor: "var(--color-line)" }}
        onClick={() => onChange(Math.min(max, value + 1))}
        disabled={value >= max}
        aria-label={`One more ${label} to move`}
      >
        +
      </button>
    </div>
  );
}
