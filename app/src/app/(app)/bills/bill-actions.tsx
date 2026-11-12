"use client";

import Link from "next/link";
import { useEffect, useRef, useState, useTransition } from "react";
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
import { NcChargeSelect } from "./nc-charge-select";
import { undoComplimentary, kotDateTransfer, outletTransfer, reopenBill, adjustBill, setItemDiscount, setCategoryDiscount, setBillNoTax, makeComplimentary, cancelItem, changePaymentMode, fireHeld, issueCreditNote, setBillCustomer, mergeBills, moveTable, payBill, splitBill, voidBill } from "./actions";

type Method = { id: string; name: string; kind: string; ask_reference: boolean; upi_id?: string | null };
type PaymentRow = { id: string; methodId: string; methodName: string; amount: number; rounded: boolean };
type Line = { id: string; name: string; options: string | null; qty: number; amount: number; at?: string };
type TableOpt = { id: string; number: string; busy: boolean };
type OtherBill = { id: string; billNumber: string; total: number; table: string | null; mergeable: boolean };
type DiscTools = { categories: { id: string; name: string }[]; itemDisc: Record<string, { kind: "percent" | "amount"; value: number }>; noTax: boolean; noTaxAllowed: boolean };
type Panel = null | "itemdisc" | "split" | "move" | "moveItem" | "merge" | "cancel" | "adjust" | "comp" | "date" | "outlet";
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
  companyAccounts = 0,
  compNow = null,
  businessDate = null,
  branchId = null,
  outlets = [],
  outletTables = [],
  serverName = null,
  lineKot = {},
  totals = null,
  discTools,
}: {
  /** Manager tools: item discount, category discount, No Tax. Undefined hides them. */
  discTools?: DiscTools;
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
  /** How many customer credit accounts can take this bill (the Company button of the Check screen). */
  companyAccounts?: number;
  /** Set when the bill is already a no-charge bill: its kind, so it can be charged again (Winsar "NoCharge KOT to KOT"). */
  compNow?: "complimentary" | "staff_meal" | null;
  /** The business day this bill counts towards (Winsar "KOT Date Transfer"). */
  businessDate?: string | null;
  /** The outlet the bill is in, and the other outlets it can move to (Winsar "KOT Table Transfer other outlet"). */
  branchId?: string | null;
  outlets?: { id: string; name: string }[];
  outletTables?: { id: string; number: string; branchId: string; busy: boolean }[];
  /** Who took the order: shown on each KOT round, as Winsar shows the steward. */
  serverName?: string | null;
  /** Which KOT each line went out on: order_item_id -> { KOT number, time }. Winsar heads each round with this. */
  lineKot?: Record<string, { no: string; at: string }>;
  /** Sub total, discount and tax of the bill, shown under the order list (Winsar shows them under its list). */
  totals?: { subtotal: number; discount: number; tax: number } | null;
}) {
  const router = useRouter();
  const online = useOnline();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  /** The line the cashier tapped in the order list: shown in blue, like the selected row in Winsar. */
  const [selLine, setSelLine] = useState<string | null>(null);
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
  const [checkOpen, setCheckOpen] = useState(false);
  // The "Check ✓" button in the bottom bar of the order screen.
  useEffect(() => {
    if (!embedded) return;
    const on = () => setCheckOpen(true);
    window.addEventListener("sna-desk-check", on);
    return () => window.removeEventListener("sna-desk-check", on);
  }, [embedded]);
  const [autoN, setAutoN] = useState(2);
  // Partial split options (Winsar): what the NEW bill gets when it is split off.
  const [splitNoTax, setSplitNoTax] = useState(false);
  const [splitNoSc, setSplitNoSc] = useState(false);
  const [splitDisc, setSplitDisc] = useState("");
  const [splitWhy, setSplitWhy] = useState("");
  // Same options for Check 1 (the bill that stays), shown in one grid with Check 2.
  const [split1NoTax, setSplit1NoTax] = useState(false);
  const [split1NoSc, setSplit1NoSc] = useState(false);
  const [split1Disc, setSplit1Disc] = useState("");
  const [win, setWin] = useState<null | "pay" | "cancel" | "void" | "fix" | "refund" | "reopen">(null);
  const [showKots, setShowKots] = useState(false);
  // Opening a window or panel starts clean: the message of the last action must not show up inside the next dialog.
  useEffect(() => {
    if (panel !== null || win !== null) {
      setError(null);
      setNotice(null);
    }
  }, [panel, win]);
  const [moveTo, setMoveTo] = useState("");
  const [mergeFrom, setMergeFrom] = useState("");
  const [splitQty, setSplitQty] = useState<Record<string, number>>({});
  const [cancelId, setCancelId] = useState(lines[0]?.id ?? "");
  const [cancelQty, setCancelQty] = useState("1");
  const [cancelReason, setCancelReason] = useState("");
  const [discAmt, setDiscAmt] = useState(adjust && adjust.discount > 0 ? String(adjust.discount) : "");
  const [discReason, setDiscReason] = useState("");
  const [idItem, setIdItem] = useState(lines[0]?.id ?? "");
  const [idKind, setIdKind] = useState<"percent" | "amount">("percent");
  const [idVal, setIdVal] = useState("");
  const [idReason, setIdReason] = useState("");
  const [catId, setCatId] = useState(discTools?.categories[0]?.id ?? "");
  const [catPct, setCatPct] = useState("");
  const [catReason, setCatReason] = useState("");
  const [ntReason, setNtReason] = useState("");
  const [compKind, setCompKind] = useState<"complimentary" | "staff_meal">("complimentary");
  const [compReason, setCompReason] = useState("");
  const [compCharge, setCompCharge] = useState("");
  const [compTargets, setCompTargets] = useState(0);
  const [unCompReason, setUnCompReason] = useState("");
  const [dateTo, setDateTo] = useState(businessDate ?? "");
  const [dateReason, setDateReason] = useState("");
  const [outletTo, setOutletTo] = useState("");
  const [outletTable, setOutletTable] = useState<string | null>(null);
  const [outletReason, setOutletReason] = useState("");
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
    : compNow
      ? "This is a no-charge bill, so it cannot be split."
      : adjust?.senior
        ? "This bill has a senior / PWD discount, so it cannot be split. Split the payment instead."
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

  /** Moves the chosen quantities (splitQty) to a new bill, with the options for the new bill. Used by the split panel and the Check screen. */
  function runSplit() {
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
        setSplitQty({});
        // Partial split options (grid): Check 2 = the new bill, Check 1 = this bill. If one is refused the bill still exists, so say so.
        const disc = Number(splitDisc) || 0;
        const disc1 = Number(split1Disc) || 0;
        const why = splitWhy.trim();
        if ((splitNoTax || disc > 0 || split1NoTax || disc1 > 0) && why.length < 3) {
          return setError(`${res.message} Write a reason, then set the options from Running bills.`);
        }
        try {
          for (const [id, noTax, noSc, d] of [
            [res.newOrderId, splitNoTax, splitNoSc, disc],
            [orderId, split1NoTax, split1NoSc, disc1],
          ] as const) {
            if (noTax) {
              const r1 = await setBillNoTax({ orderId: id, on: true, reason: why });
              if (!r1.ok) return setError(`${res.message} But: ${r1.error}`);
            }
            if (d > 0 || noSc) {
              const r2 = await adjustBill({ orderId: id, discount: d, reason: d > 0 ? why : null, serviceCharge: noSc ? false : null });
              if (!r2.ok) return setError(`${res.message} But: ${r2.error}`);
            }
          }
        } catch {
          return setError(`${res.message} The options could not be saved; open that bill and set them there.`);
        }
        setSplitNoTax(false); setSplitNoSc(false); setSplitDisc(""); setSplitWhy("");
        setSplit1NoTax(false); setSplit1NoSc(false); setSplit1Disc("");
        router.push(embedded ? `/pos?bill=${res.newOrderId}` : `/bills/${res.newOrderId}`);
      });
  }

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
  if (!showPay && !showRefund && !showVoid && !showFix && !showBuyer && !showFire && !showReopen && !canKots && !notice) return null;

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

      {embedded && checkOpen && showPay && (
        <div className="fixed inset-0 z-[45] flex flex-col gap-3 overflow-y-auto p-3" style={{ background: "var(--color-surface-2, #f6f3ea)" }} role="dialog" aria-label="Check">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="text-base font-bold">Check · bill {billNumber}</div>
            <div className="flex items-center gap-2">
              {discTools && (
                <button type="button" className="btn border text-sm" style={{ borderColor: discTools.noTax ? "var(--color-brand)" : "var(--color-line)" }} onClick={() => setPanel("itemdisc")} title="Take the tax off this bill (needs the owner's permission for this outlet)">
                  No Tax {discTools.noTax ? "· ON" : ""}
                </button>
              )}
              {adjust?.scAvailable && (
                <button type="button" className="btn border text-sm" style={{ borderColor: !adjust.scOn ? "var(--color-brand)" : "var(--color-line)" }} onClick={() => setPanel("adjust")} title="Take the service charge off this bill">
                  No S.C. {!adjust.scOn ? "· ON" : ""}
                </button>
              )}
              <button type="button" className="btn btn-primary text-sm" onClick={() => setCheckOpen(false)}>
                ← Back
              </button>
            </div>
          </div>

          {splitBlocked && <p className="rounded-md border p-2 text-xs" style={{ borderColor: "var(--color-line)", color: "var(--color-ink-3)" }}>{splitBlocked}</p>}

          <div className="grid min-h-0 gap-3 md:grid-cols-2">
            {([1, 2] as const).map((n) => {
              const rows = lines
                .map((l) => ({ l, q: n === 1 ? l.qty - (splitQty[l.id] ?? 0) : splitQty[l.id] ?? 0 }))
                .filter((r) => r.q > 0);
              const sum = rows.reduce((t, r) => t + (r.l.amount / r.l.qty) * r.q, 0);
              return (
                <section key={n} className="card flex min-h-[220px] flex-col p-3">
                  <div className="flex items-center justify-between border-b pb-2 text-sm font-bold" style={{ borderColor: "var(--color-line)" }}>
                    <span>{n === 1 ? "Check 1 · this bill" : "Check 2 · new bill"}</span>
                    <span>{m(sum)}</span>
                  </div>
                  <ul className="flex-1 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
                    {rows.length === 0 && (
                      <li className="py-6 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {n === 1 ? "Nothing left on this bill." : "Tap → on an item to move one to the new bill."}
                      </li>
                    )}
                    {rows.map(({ l, q }) => (
                      <li key={l.id} className="flex items-center gap-2 py-1.5">
                        {n === 2 && (
                          <button type="button" className="h-8 w-8 shrink-0 rounded-full border font-bold" style={{ borderColor: "var(--color-line)" }} aria-label={`Move one ${l.name} back`} onClick={() => setSplitQty((c) => ({ ...c, [l.id]: Math.max(0, (c[l.id] ?? 0) - 1) }))}>
                            ←
                          </button>
                        )}
                        <span className="min-w-0 flex-1 truncate">
                          {l.name}
                          {l.options ? <span style={{ color: "var(--color-ink-3)" }}> · {l.options}</span> : null}
                        </span>
                        <span className="w-8 text-center">{q}</span>
                        <span className="w-16 text-right">{m((l.amount / l.qty) * q)}</span>
                        {n === 1 && (
                          <button type="button" disabled={!!splitBlocked} className="h-8 w-8 shrink-0 rounded-full border font-bold disabled:opacity-40" style={{ borderColor: "var(--color-line)" }} aria-label={`Move one ${l.name} to the new bill`} onClick={() => setSplitQty((c) => ({ ...c, [l.id]: Math.min(l.qty, (c[l.id] ?? 0) + 1) }))}>
                            →
                          </button>
                        )}
                      </li>
                    ))}
                  </ul>
                </section>
              );
            })}
          </div>

          {totals && (
            <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border px-3 py-2 text-sm" style={{ borderColor: "var(--color-line)" }}>
              <span>Sub total {m(totals.subtotal)}</span>
              {totals.discount > 0 && <span>Discount −{m(totals.discount)}</span>}
              <span>Taxes {m(totals.tax)}</span>
              <span className="font-bold">Total {m(grandTotal)}</span>
            </div>
          )}

          {(error || notice) && <p className="text-sm" style={{ color: error ? "var(--color-bad)" : undefined }}>{error ?? notice}</p>}

          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4 lg:grid-cols-6">
            <button type="button" className="btn btn-primary text-sm" disabled={pending || !!splitBlocked || splitCount === 0 || splitCount >= lines.reduce((t, l) => t + l.qty, 0)} onClick={runSplit}>
              {pending ? "Splitting…" : splitCount > 0 ? `Split (${splitCount} to Check 2)` : "Split"}
            </button>
            <PanelButton label="Split options / Auto split" active={panel === "split"} disabled={!!splitBlocked} onClick={() => setPanel("split")} />
            {showAdjust && <PanelButton label={adjust?.scAvailable ? "Discount / service" : "Discount"} active={panel === "adjust"} onClick={() => setPanel("adjust")} />}
            {discTools && lines.length > 0 && <PanelButton label="Item Disc" active={panel === "itemdisc"} onClick={() => setPanel("itemdisc")} />}
            <PanelButton label="Move table" active={panel === "move"} onClick={() => setPanel("move")} />
            <PanelButton label="Move item" active={panel === "moveItem"} disabled={!online} title={online ? undefined : needsInternetText("move_item")} onClick={() => setPanel("moveItem")} />
            {canMerge && <PanelButton label="Merge bills" active={panel === "merge"} onClick={() => setPanel("merge")} />}
            {open && (canVoid || canAsk) && lines.length > 0 && !dayClosed && <PanelButton label="Cancel item" active={win === "cancel"} onClick={() => setWin("cancel")} />}
            {showVoid && <PanelButton label="Void bill" active={win === "void"} onClick={() => setWin("void")} />}
            {showAdjust && !adjust?.senior && <PanelButton label="Complimentary / staff meal" active={panel === "comp"} onClick={() => setPanel("comp")} />}
            {canVoid && !hasPayments && <PanelButton label="KOT date transfer" active={panel === "date"} onClick={() => setPanel("date")} />}
            {canVoid && !hasPayments && outlets.length > 1 && <PanelButton label="Move to another outlet" active={panel === "outlet"} onClick={() => setPanel("outlet")} />}
            <button
              type="button"
              className="btn border text-sm"
              style={{ borderColor: "var(--color-line)" }}
              disabled={companyAccounts === 0}
              title={companyAccounts === 0 ? "No customer credit accounts are set up (Accounts)" : "Charge this bill to a company / customer account (pay later)"}
              onClick={() => { setCheckOpen(false); window.dispatchEvent(new Event("sna-desk-company")); }}
            >
              Company
            </button>
            <Link href={`/bills/settle/${orderId}`} className="btn border text-center text-sm" style={{ borderColor: "var(--color-line)" }} title="Take an advance: add a payment smaller than the balance on the settlement screen; the bill stays part-paid">
              Advance
            </Link>
            <button type="button" className="btn border text-sm" style={{ borderColor: "var(--color-brand)", color: "var(--color-brand-strong)" }} title="Print the bill as an estimate for the guest. It is not a tax invoice." onClick={() => window.dispatchEvent(new Event("sna-desk-estimate"))}>
              Estimate
            </button>
            <button type="button" className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => window.dispatchEvent(new Event("sna-desk-print"))}>
              Print
            </button>
            <button type="button" className="btn btn-pay text-sm" onClick={() => { setCheckOpen(false); setWin("pay"); }}>
              Settle · {m(balance)}
            </button>
            <Link href={`/bills/settle/${orderId}`} className="btn border text-center text-sm" style={{ borderColor: "var(--color-brand)", color: "var(--color-brand-strong)" }}>
              Settlement screen
            </Link>
          </div>
        </div>
      )}

      {showPay && (
        <section className={embedded ? "card order-first p-4" : "card p-4"}>
          <h2 className="text-sm font-bold">{embedded ? "Order so far" : "Table & items"}</h2>

          {embedded && lines.length > 0 && lines.some((l) => l.at) && (
            <div className="mt-2 overflow-hidden rounded-lg border text-sm" style={{ borderColor: "var(--color-line)" }}>
              {(() => {
                const groups: { key: string; at: string; no: string | null; items: Line[] }[] = [];
                for (const l of lines) {
                  const k = lineKot[l.id]?.no ?? (l.at ?? "").slice(0, 19);
                  const g = groups[groups.length - 1];
                  if (g && g.key === k) g.items.push(l);
                  else groups.push({ key: k, at: lineKot[l.id]?.at ?? l.at ?? "", no: lineKot[l.id]?.no ?? null, items: [l] });
                }
                return groups.map((g, i) => (
                  <div key={g.key + i}>
                    <div className="px-2 py-1 text-center text-[11px] font-bold text-white" style={{ background: "#B8960C" }}>
                      {g.no ? `KOT No : ${g.no}` : `KOT round ${i + 1}`}
                      {serverName ? ` · ${serverName}` : ""}
                      {g.at ? ` · ${new Date(g.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}` : ""}
                    </div>
                    {g.items.map((l) => (
                      <div
                        key={l.id}
                        onClick={() => setSelLine(selLine === l.id ? null : l.id)}
                        aria-selected={selLine === l.id}
                        className="flex cursor-pointer items-center justify-between gap-2 px-2 py-1"
                        style={{ borderTop: "1px solid var(--color-line)", background: selLine === l.id ? "#1c64c8" : undefined, color: selLine === l.id ? "#fff" : undefined }}
                      >
                        <span className="min-w-0 flex-1 truncate">
                          {l.name}
                          {l.options ? <span style={{ color: "var(--color-ink-3)" }}> · {l.options}</span> : null}
                        </span>
                        {open && (canVoid || canAsk) && !dayClosed ? (
                          <button
                            type="button"
                            className="h-6 w-6 shrink-0 rounded-full border text-sm font-bold leading-none"
                            style={{ borderColor: "var(--color-line)", color: "var(--color-bad)" }}
                            aria-label={`Cancel one ${l.name}`}
                            title="Cancel one (a reason is asked)"
                            onClick={() => {
                              setCancelId(l.id);
                              setCancelQty("1");
                              setWin("cancel");
                            }}
                          >
                            −
                          </button>
                        ) : null}
                        {open && !dayClosed && online ? (
                          <button
                            type="button"
                            className="h-6 w-6 shrink-0 rounded-full border text-sm font-bold leading-none"
                            style={{ borderColor: "var(--color-line)", color: "var(--color-brand-strong)" }}
                            aria-label={`Add one more ${l.name}`}
                            title="Add one more to the new items"
                            onClick={() => window.dispatchEvent(new CustomEvent("sna-desk-plus", { detail: l.id }))}
                          >
                            +
                          </button>
                        ) : null}
                        <span className="w-8 text-center">{l.qty}</span>
                        <span className="w-16 text-right">{m(l.amount)}</span>
                      </div>
                    ))}
                  </div>
                ));
              })()}
              <div id="desk-new-rows" />
              <div className="flex items-center justify-between px-2 py-1 text-xs font-bold" style={{ borderTop: "1px solid var(--color-line)", background: "var(--color-surface-2)" }}>
                <span style={{ color: "var(--color-brand-strong)" }}>QTY : {lines.reduce((n, l) => n + l.qty, 0)}</span>
                <span>{m(lines.reduce((n, l) => n + l.amount, 0))}</span>
              </div>
            </div>
          )}

          {embedded && totals && lines.length > 0 && (
            <div className="mt-2 rounded-lg border px-2 py-1.5 text-sm" style={{ borderColor: "var(--color-line)" }}>
              <div className="flex justify-between text-xs" style={{ color: "var(--color-ink-3)" }}>
                <span>Sub total</span>
                <span>{m(totals.subtotal)}</span>
              </div>
              {totals.discount > 0 && (
                <div className="flex justify-between text-xs" style={{ color: "var(--color-ink-3)" }}>
                  <span>Discount</span>
                  <span>−{m(totals.discount)}</span>
                </div>
              )}
              <div className="flex justify-between text-xs" style={{ color: "var(--color-ink-3)" }}>
                <span>Taxes</span>
                <span>{m(totals.tax)}</span>
              </div>
              <div className="mt-0.5 flex justify-between border-t pt-0.5 font-bold" style={{ borderColor: "var(--color-line)" }}>
                <span>Total</span>
                <span>{m(grandTotal)}</span>
              </div>
              <div id="desk-new-total" data-total={grandTotal} />
            </div>
          )}

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
              <PanelButton label="Check ✓" active={checkOpen} onClick={() => setCheckOpen(true)} />
            )}
            {embedded && (
              <>
                <button type="button" className="btn btn-pay col-span-2 text-sm" onClick={() => setWin("pay")}>
                  Settle · {m(balance)}
                </button>
                <Link href={`/bills/settle/${orderId}`} className="btn col-span-2 border text-sm" style={{ borderColor: "var(--color-brand)", color: "var(--color-brand-strong)" }} title="The full settlement screen: several payments, tips and a running balance">
                  Settlement screen
                </Link>
              </>
            )}
            {!embedded && (<>
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
            {discTools && lines.length > 0 && (
              <PanelButton label="Item / category discount" active={panel === "itemdisc"} onClick={() => setPanel(panel === "itemdisc" ? null : "itemdisc")} />
            )}
            {embedded && open && (canVoid || canAsk) && lines.length > 0 && !dayClosed && (
              <PanelButton label="Cancel item" active={win === "cancel"} onClick={() => setWin("cancel")} />
            )}
            {embedded && showVoid && <PanelButton label="Void bill" active={win === "void"} onClick={() => setWin("void")} />}
            {showAdjust && !adjust?.senior && (
              <PanelButton label="Complimentary / staff meal" active={panel === "comp"} onClick={() => setPanel(panel === "comp" ? null : "comp")} />
            )}
            {canVoid && !hasPayments && (
              <PanelButton label="KOT date transfer" active={panel === "date"} onClick={() => setPanel(panel === "date" ? null : "date")} />
            )}
            {canVoid && !hasPayments && outlets.length > 1 && (
              <PanelButton label="Move to another outlet" active={panel === "outlet"} onClick={() => setPanel(panel === "outlet" ? null : "outlet")} />
            )}
            </>)}
          </div>

          {!online && (
            <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
              {needsInternetText("add_to_bill")} {needsInternetText("move_item")}
            </p>
          )}

          <PanelFrame
            modal={embedded && panel !== null}
            title={panel === "date" ? "KOT date transfer" : panel === "outlet" ? "Move to another outlet" : panel === "itemdisc" ? "Item / category discount" : panel === "comp" ? "Complimentary / staff meal" : panel === "adjust" ? "Discount" : panel === "split" ? "Split bill" : panel === "move" ? "Move table" : panel === "moveItem" ? "Move item" : "Merge bills"}
            error={error}
            notice={notice}
            onClose={() => setPanel(null)}
          >
          {panel === "itemdisc" && discTools && (
            <div className="mt-3 space-y-4 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              <div className="space-y-2">
                <h3 className="text-xs font-bold">Item discount</h3>
                <select className="field h-10 text-sm" aria-label="Item" value={idItem} onChange={(e) => setIdItem(e.target.value)}>
                  {lines.map((l) => (
                    <option key={l.id} value={l.id}>
                      {l.qty} × {l.name} · {m(l.amount)}
                      {discTools.itemDisc[l.id] ? ` (now ${discTools.itemDisc[l.id].value}${discTools.itemDisc[l.id].kind === "percent" ? "%" : ""} off)` : ""}
                    </option>
                  ))}
                </select>
                <div className="flex gap-2">
                  <div className="grid w-28 shrink-0 grid-cols-2 gap-1" role="radiogroup" aria-label="Kind">
                    {(["percent", "amount"] as const).map((k) => (
                      <button key={k} role="radio" aria-checked={idKind === k} className="btn border text-sm" style={{ borderColor: idKind === k ? "var(--color-brand)" : "var(--color-line)", background: idKind === k ? "var(--color-brand-soft)" : undefined }} onClick={() => setIdKind(k)}>
                        {k === "percent" ? "%" : currency}
                      </button>
                    ))}
                  </div>
                  <input className="field h-10 min-w-0 flex-1 text-sm" inputMode="decimal" placeholder={idKind === "percent" ? "e.g. 10" : "Amount off"} aria-label="Discount value" value={idVal} onChange={(e) => setIdVal(e.target.value)} />
                </div>
                <input className="field h-10 text-sm" placeholder="Reason (required)" aria-label="Reason" value={idReason} onChange={(e) => setIdReason(e.target.value)} maxLength={200} />
                <div className="grid grid-cols-2 gap-2">
                  <span className="text-[11px] font-semibold" style={{ color: "var(--color-bad)" }}>
                    {idItem ? `(Max disc : ${m(lines.find((l) => l.id === idItem)?.amount ?? 0)})` : ""}
                  </span>
                  <button className="btn btn-primary text-sm" disabled={pending || !idItem || !(Number(idVal) > 0) || idReason.trim().length < 3} onClick={() => run(() => setItemDiscount({ orderId, itemId: idItem, kind: idKind, value: Number(idVal), reason: idReason }), () => { setIdVal(""); setIdReason(""); })}>
                    {pending ? "Saving…" : "Apply"}
                  </button>
                  <button className="btn border text-sm" disabled={pending || !discTools.itemDisc[idItem]} onClick={() => run(() => setItemDiscount({ orderId, itemId: idItem, kind: "percent", value: 0, reason: "" }))}>
                    Remove
                  </button>
                </div>
              </div>

              {discTools.categories.length > 0 && (
                <div className="space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
                  <h3 className="text-xs font-bold">Category discount (%)</h3>
                  <select className="field h-10 text-sm" aria-label="Category" value={catId} onChange={(e) => setCatId(e.target.value)}>
                    {discTools.categories.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.name}
                      </option>
                    ))}
                  </select>
                  <input className="field h-10 text-sm" inputMode="decimal" placeholder="Percent off every item in the category" aria-label="Category percent" value={catPct} onChange={(e) => setCatPct(e.target.value)} />
                  <input className="field h-10 text-sm" placeholder="Reason (required)" aria-label="Category reason" value={catReason} onChange={(e) => setCatReason(e.target.value)} maxLength={200} />
                  <div className="grid grid-cols-2 gap-2">
                    <button className="btn btn-primary text-sm" disabled={pending || !catId || !(Number(catPct) > 0) || catReason.trim().length < 3} onClick={() => run(() => setCategoryDiscount({ orderId, categoryId: catId, percent: Number(catPct), reason: catReason }), () => { setCatPct(""); setCatReason(""); })}>
                      {pending ? "Saving…" : "Apply"}
                    </button>
                    <button className="btn border text-sm" disabled={pending || !catId} onClick={() => run(() => setCategoryDiscount({ orderId, categoryId: catId, percent: 0, reason: "" }))}>
                      Remove
                    </button>
                  </div>
                </div>
              )}

              {(discTools.noTaxAllowed || discTools.noTax) && (
                <div className="space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
                  <h3 className="text-xs font-bold">No tax</h3>
                  <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                    {discTools.noTax
                      ? "Tax is taken off this bill."
                      : "Takes the tax off this whole bill. Only for a customer who does not have to pay it (for example a tax-exempt buyer). It is recorded with your reason."}
                  </p>
                  <input className="field h-10 text-sm" placeholder="Reason (required)" aria-label="No tax reason" value={ntReason} onChange={(e) => setNtReason(e.target.value)} maxLength={200} />
                  <button className="btn btn-primary w-full text-sm" disabled={pending || ntReason.trim().length < 3} onClick={() => run(() => setBillNoTax({ orderId, on: !discTools.noTax, reason: ntReason }), () => setNtReason(""))}>
                    {pending ? "Saving…" : discTools.noTax ? "Put tax back" : "Take tax off this bill"}
                  </button>
                </div>
              )}
            </div>
          )}

          {panel === "date" && (
            <div className="mt-3 space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                The bill counts towards another business day. Only an unpaid bill, only a day that is not closed, and only within
                seven days of {businessDate ?? "its day"}. The bill number does not change.
              </p>
              <label className="block text-xs font-semibold" htmlFor="kotdate">New business date</label>
              <input id="kotdate" type="date" className="field h-10 w-full text-sm" value={dateTo} onChange={(e) => setDateTo(e.target.value)} />
              <input className="field h-10 w-full text-sm" placeholder="Reason" aria-label="Reason" maxLength={200} value={dateReason} onChange={(e) => setDateReason(e.target.value)} />
              <button
                className="btn btn-primary mt-1 w-full text-sm"
                disabled={pending || !dateTo || dateTo === businessDate || dateReason.trim().length < 3}
                onClick={() => run(() => kotDateTransfer({ orderId, date: dateTo, reason: dateReason }), () => setDateReason(""))}
              >
                {pending ? "Moving…" : "Move this bill to that day"}
              </button>
            </div>
          )}

          {panel === "outlet" && (
            <div className="mt-3 space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                An unpaid bill moves to another outlet, onto a free table there or to its counter. The bill keeps its number, so it
                stays in the series of the outlet that opened it.
              </p>
              <div className="flex flex-wrap gap-1.5">
                {outlets.filter((o) => o.id !== branchId).map((o) => (
                  <button
                    key={o.id}
                    type="button"
                    onClick={() => { setOutletTo(o.id); setOutletTable(null); }}
                    className="rounded-md border px-2.5 py-1 text-xs font-semibold"
                    style={{ borderColor: outletTo === o.id ? "var(--color-brand)" : "var(--color-line)", background: outletTo === o.id ? "var(--color-brand)" : "transparent", color: outletTo === o.id ? "#fff" : "var(--color-ink-2)" }}
                  >
                    {o.name}
                  </button>
                ))}
              </div>
              {outletTo && (
                <div className="flex flex-wrap gap-1.5">
                  <button
                    type="button"
                    onClick={() => setOutletTable(null)}
                    className="rounded-md border px-2.5 py-1 text-xs font-semibold"
                    style={{ borderColor: outletTable === null ? "var(--color-brand)" : "var(--color-line)", background: outletTable === null ? "var(--color-brand)" : "transparent", color: outletTable === null ? "#fff" : "var(--color-ink-2)" }}
                  >
                    Counter
                  </button>
                  {outletTables.filter((t) => t.branchId === outletTo).map((t) => (
                    <button
                      key={t.id}
                      type="button"
                      disabled={t.busy}
                      onClick={() => setOutletTable(t.id)}
                      className="rounded-md border px-2.5 py-1 text-xs font-semibold disabled:opacity-40"
                      style={{ borderColor: outletTable === t.id ? "var(--color-brand)" : "var(--color-line)", background: outletTable === t.id ? "var(--color-brand)" : "transparent", color: outletTable === t.id ? "#fff" : "var(--color-ink-2)" }}
                    >
                      T{t.number}
                    </button>
                  ))}
                </div>
              )}
              <input className="field h-10 w-full text-sm" placeholder="Reason" aria-label="Reason" maxLength={200} value={outletReason} onChange={(e) => setOutletReason(e.target.value)} />
              <button
                className="btn btn-primary mt-1 w-full text-sm"
                disabled={pending || !outletTo || outletReason.trim().length < 3}
                onClick={() => run(() => outletTransfer({ orderId, branchId: outletTo, tableId: outletTable, reason: outletReason }), () => setOutletReason(""))}
              >
                {pending ? "Moving…" : "Move this bill to that outlet"}
              </button>
            </div>
          )}

          {panel === "comp" && compNow && (
            <div className="mt-3 space-y-2 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
              <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                This bill is already {compNow === "complimentary" ? "complimentary" : "a staff meal"}. Charging it again puts the
                items back at their prices, so the guest pays. A manager approves it.
              </p>
              <input className="field h-10 w-full text-sm" placeholder="Reason" aria-label="Reason" maxLength={200} value={unCompReason} onChange={(e) => setUnCompReason(e.target.value)} />
              <button
                className="btn btn-primary mt-1 w-full text-sm"
                disabled={pending || unCompReason.trim().length < 3}
                onClick={() => run(() => undoComplimentary({ orderId, reason: unCompReason }), () => setUnCompReason(""))}
              >
                {pending ? "Saving…" : "Charge this bill again"}
              </button>
            </div>
          )}

          {panel === "comp" && !compNow && (
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
              <NcChargeSelect value={compCharge} onChange={setCompCharge} onCount={setCompTargets} />
              <button
                className="btn btn-primary mt-1 w-full text-sm"
                disabled={pending || compReason.trim().length < 3 || (compTargets > 0 && !compCharge)}
                onClick={() => run(() => makeComplimentary({ orderId, kind: compKind, reason: compReason, chargeTo: compCharge || null }), () => { setCompReason(""); setCompCharge(""); })}
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
                      reason: discNum > 0 ? discReason || null : null,
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
                  <div className="mt-3 rounded-md border p-2" style={{ borderColor: "var(--color-line)" }}>
                    <div className="mb-1 text-xs font-bold">Options for each check (optional)</div>
                    <table className="w-full text-sm" aria-label="Split options">
                      <thead>
                        <tr className="text-left text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                          <th className="py-1 pr-2 font-semibold">Check</th>
                          <th className="px-2 font-semibold">Discount</th>
                          <th className="px-2 text-center font-semibold">No Tax</th>
                          <th className="px-2 text-center font-semibold">No S.C.</th>
                        </tr>
                      </thead>
                      <tbody>
                        {([1, 2] as const).map((n) => {
                          const disc = n === 1 ? split1Disc : splitDisc;
                          const setDisc = n === 1 ? setSplit1Disc : setSplitDisc;
                          const noTax = n === 1 ? split1NoTax : splitNoTax;
                          const setNoTax = n === 1 ? setSplit1NoTax : setSplitNoTax;
                          const noSc = n === 1 ? split1NoSc : splitNoSc;
                          const setNoSc = n === 1 ? setSplit1NoSc : setSplitNoSc;
                          return (
                            <tr key={n} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                              <td className="py-1 pr-2 text-xs font-semibold">{n === 1 ? "Check 1 (this bill)" : "Check 2 (new bill)"}</td>
                              <td className="px-2">
                                <input inputMode="decimal" className="field h-8 w-20 text-sm" aria-label={`Check ${n} discount`} value={disc} onChange={(e) => setDisc(e.target.value.replace(/[^0-9.]/g, ""))} placeholder="0.00" />
                              </td>
                              <td className="px-2 text-center">
                                <input type="checkbox" aria-label={`Check ${n} no tax`} disabled={!discTools?.noTaxAllowed} checked={noTax} onChange={(e) => setNoTax(e.target.checked)} />
                              </td>
                              <td className="px-2 text-center">
                                <input type="checkbox" aria-label={`Check ${n} no service charge`} checked={noSc} onChange={(e) => setNoSc(e.target.checked)} />
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                    {(splitNoTax || Number(splitDisc) > 0 || split1NoTax || Number(split1Disc) > 0) && (
                      <input
                        className="field mt-2 h-8 w-full text-sm"
                        value={splitWhy}
                        onChange={(e) => setSplitWhy(e.target.value)}
                        placeholder="Reason (needed for no tax or a discount)"
                      />
                    )}
                    <p className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                      Applied right after the split. Each one needs the same manager right as on a normal bill. A discount typed for Check 1 replaces the discount it has now.
                    </p>
                  </div>
                  <button
                    className="btn btn-primary mt-3 w-full text-sm"
                    disabled={pending || splitCount === 0 || splitCount >= lines.reduce((s, l) => s + l.qty, 0)}
                    onClick={runSplit}
                  >
                    {pending ? "Splitting…" : `Move ${splitCount || ""} to a new bill`}
                  </button>
                  <div className="mt-4 border-t pt-3" style={{ borderColor: "var(--color-line)" }}>
                    <div className="mb-1 text-xs font-bold">Auto split</div>
                    <p className="mb-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                      Shares the items one by one into this many bills (by number of items, not by amount). Tax and totals are worked out again for each bill.
                    </p>
                    <div className="flex items-center gap-2">
                      {[2, 3, 4, 5].map((n) => (
                        <button
                          key={n}
                          type="button"
                          onClick={() => setAutoN(n)}
                          className="h-9 w-9 rounded-md border text-sm font-semibold"
                          style={{ borderColor: autoN === n ? "var(--color-brand)" : "var(--color-line)", background: autoN === n ? "var(--color-brand)" : "transparent", color: autoN === n ? "#fff" : "var(--color-ink-2)" }}
                        >
                          {n}
                        </button>
                      ))}
                      <button
                        className="btn btn-primary flex-1 text-sm"
                        disabled={pending || lines.reduce((s, l) => s + l.qty, 0) < autoN}
                        onClick={() => {
                          setError(null);
                          // Every unit goes to bill (i mod N). Bill 0 stays on this bill; the others are split off one after another.
                          const bills: Record<string, number>[] = Array.from({ length: autoN }, () => ({}));
                          let i = 0;
                          for (const l of lines) for (let u = 0; u < l.qty; u++, i++) bills[i % autoN][l.id] = (bills[i % autoN][l.id] ?? 0) + 1;
                          start(async () => {
                            for (let b = 1; b < autoN; b++) {
                              const items = Object.entries(bills[b]).map(([order_item_id, qty]) => ({ order_item_id, qty }));
                              if (items.length === 0) continue;
                              try {
                                const res = await splitBill({ orderId, items, clientRef: crypto.randomUUID() });
                                if (!res.ok) return setError(`${res.error} (${b - 1} of ${autoN - 1} bills were made; the rest are still on this bill.)`);
                              } catch {
                                return setError("The internet dropped while splitting. Look at the open bills before you press again.");
                              }
                            }
                            router.push(embedded ? `/pos?bill=${orderId}` : `/bills/${orderId}`);
                            router.refresh();
                          });
                        }}
                      >
                        {pending ? "Splitting…" : `Split into ${autoN} bills`}
                      </button>
                    </div>
                  </div>
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
