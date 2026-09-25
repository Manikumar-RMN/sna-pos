"use client";

import Link from "next/link";
import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money, roundCash } from "@/lib/format";
import { cancelItem, mergeBills, moveTable, payBill, refundBill, splitBill, voidBill } from "./actions";

type Method = { id: string; name: string; kind: string };
type Line = { id: string; name: string; options: string | null; qty: number; amount: number };
type TableOpt = { id: string; number: string; busy: boolean };
type OtherBill = { id: string; billNumber: string; total: number; table: string | null; mergeable: boolean };
type Panel = null | "split" | "move" | "merge" | "cancel";

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
}: {
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
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const m = (n: number) => money(n, currency);

  const [methodId, setMethodId] = useState(methods[0]?.id ?? "");
  const [tendered, setTendered] = useState("");
  const [partAmt, setPartAmt] = useState("");
  const [refundAmt, setRefundAmt] = useState("");
  const [refundReason, setRefundReason] = useState("");
  const [voidReason, setVoidReason] = useState("");
  const [confirm, setConfirm] = useState<null | "void" | "refund" | "cancel">(null);
  const [panel, setPanel] = useState<Panel>(null);
  const [moveTo, setMoveTo] = useState("");
  const [mergeFrom, setMergeFrom] = useState("");
  const [splitQty, setSplitQty] = useState<Record<string, number>>({});
  const [cancelId, setCancelId] = useState(lines[0]?.id ?? "");
  const [cancelQty, setCancelQty] = useState("1");
  const [cancelReason, setCancelReason] = useState("");

  const open = state === "unpaid" || state === "part-paid";
  const remaining = Math.max(0, Math.round((paidTotal - refunded) * 100) / 100);
  const isCash = methods.find((x) => x.id === methodId)?.kind === "cash";
  const part = partAmt.trim() === "" ? null : Math.round(Number(partAmt) * 100) / 100;
  const isFull = part === null || part >= balance;
  const due = isFull ? (isCash ? roundCash(balance, cashRounding) : balance) : part;
  const change = isCash && Number(tendered) > due ? Math.round((Number(tendered) - due) * 100) / 100 : 0;
  // Each person's share of the whole bill (not of what is left), so every payer is offered the same amount.
  const equalShare = (n: number) => Math.min(balance, Math.ceil(Math.round(grandTotal * 100) / n) / 100);

  const showPay = open && canPay;
  const showRefund = canRefund && (state === "paid" || state === "part-refunded") && remaining > 0;
  const showVoid = canVoid && state !== "voided" && refunded === 0;
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

  function run(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) {
    setError(null);
    setNotice(null);
    start(async () => {
      const res = await fn();
      if (!res.ok) {
        setError(res.error ?? "Something went wrong.");
        return;
      }
      setNotice(res.message ?? "Done.");
      setConfirm(null);
      setPanel(null);
      setVoidReason("");
      setRefundReason("");
      setRefundAmt("");
      setTendered("");
      setPartAmt("");
      setCancelReason("");
      setSplitQty({});
      after?.();
      router.refresh();
    });
  }

  if (!showPay && !showRefund && !showVoid && !notice) return null;

  return (
    <div className="no-print mx-auto mt-4 max-w-sm space-y-3">
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

      {showPay && (
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

              {isCash && (
                <div className="mt-2 flex items-center gap-2">
                  <input className="field h-10 flex-1 text-sm" inputMode="decimal" placeholder="Cash received" value={tendered} onChange={(e) => setTendered(e.target.value)} />
                  <span className="text-sm">
                    Change <b>{m(change)}</b>
                  </span>
                </div>
              )}
              <button
                className="btn btn-primary mt-3 w-full"
                disabled={pending || !methodId || (part !== null && !(part > 0)) || (part !== null && part > balance) || (isCash && tendered !== "" && Number(tendered) < due)}
                onClick={() =>
                  run(() =>
                    payBill({
                      orderId,
                      paymentMethodId: methodId,
                      tendered: isCash && tendered !== "" ? Number(tendered) : null,
                      amount: isFull ? null : part,
                    }),
                  )
                }
              >
                {pending ? "Saving…" : part !== null && part > balance ? `Only ${m(balance)} is left` : `Take ${m(due)}${isFull ? "" : " (part)"}`}
              </button>
            </>
          )}
        </section>
      )}

      {showPay && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Table &amp; items</h2>
          <div className="mt-3 grid grid-cols-2 gap-2">
            <Link href={`/pos?add=${orderId}`} className="btn btn-primary text-sm">
              + Add items
            </Link>
            <PanelButton label="Split bill" active={panel === "split"} onClick={() => setPanel(panel === "split" ? null : "split")} />
            <PanelButton label="Move table" active={panel === "move"} onClick={() => setPanel(panel === "move" ? null : "move")} />
            <PanelButton label="Merge bills" active={panel === "merge"} onClick={() => setPanel(panel === "merge" ? null : "merge")} />
          </div>

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
                      start(async () => {
                        const res = await splitBill({
                          orderId,
                          items: Object.entries(splitQty).map(([order_item_id, qty]) => ({ order_item_id, qty })),
                        });
                        if (!res.ok) return setError(res.error);
                        router.push(`/bills/${res.newOrderId}`);
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
                </>
              )}
            </div>
          )}
        </section>
      )}

      {open && canVoid && lines.length > 0 && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Cancel an item</h2>
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
            <input className="field h-10 w-20 text-center text-sm" inputMode="numeric" value={cancelQty} onChange={(e) => setCancelQty(e.target.value)} aria-label="How many to cancel" />
            <input className="field h-10 flex-1 text-sm" placeholder="Reason (required)" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} />
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
      )}

      {showRefund && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Refund</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Up to {m(remaining)} can be refunded. The bill stays on record.
          </p>
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
                onClick={() => run(() => refundBill({ orderId, amount: Number(refundAmt), reason: refundReason }))}
              >
                {pending ? "Saving…" : `Confirm refund ${m(Number(refundAmt) || 0)}`}
              </button>
            </div>
          ) : (
            <button
              className="btn mt-3 w-full border text-sm"
              style={{ borderColor: "var(--color-line)" }}
              disabled={!(Number(refundAmt) > 0) || refundReason.trim().length < 3}
              onClick={() => setConfirm("refund")}
            >
              Refund…
            </button>
          )}
        </section>
      )}

      {showVoid && (
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
      )}
    </div>
  );
}

function PanelButton({ label, active, onClick }: { label: string; active: boolean; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      aria-expanded={active}
      className="btn border text-sm"
      style={{
        borderColor: active ? "var(--color-brand)" : "var(--color-line)",
        background: active ? "var(--color-brand-soft)" : "var(--color-surface)",
      }}
    >
      {label}
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
