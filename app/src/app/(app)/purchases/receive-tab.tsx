"use client";

import { useRef, useState } from "react";
import { addDays, money } from "@/lib/format";
import { cancelGoodsReceipt, receiveGoods } from "./actions";
import { ReturnForm } from "./return-form";
import {
  BLANK_LINE,
  amountCents,
  checkLines,
  dayLabel,
  linesCents,
  linesTaxCents,
  payMethods,
  refFor,
  remainingLines,
  type Ingredient,
  type IngredientNames,
  type LineDraft,
  type OrderRow,
  type PayMethod,
  type PaymentRow,
  type ReceiptRow,
  type SentRef,
  type SupplierPick,
} from "./helpers";
import { ClaimBox } from "./claim-box";
import { LineEditor } from "./line-editor";
import { PayForm } from "./pay-form";
import { PaymentsList } from "./payments-list";
import { AddSupplierFirst, Badge, Field, Msg, lineStyle, rowBtn, useRun, type Note } from "./ui";

type Paid = "no" | "full" | "part";
const PAID: readonly (readonly [Paid, string])[] = [
  ["no", "Not yet"],
  ["full", "Paid in full"],
  ["part", "Paid part"],
];

export function ReceiveTab({
  suppliers,
  supplierNames,
  ingredients,
  names,
  openOrders,
  receipts,
  payments,
  currency,
  country,
  today,
  initialPo,
  canTill,
  claimTax,
  canSetClaim,
  agreedRates,
  canBackdate,
  backdateDays,
  directReceiving,
}: {
  /** Active suppliers. */
  suppliers: SupplierPick[];
  /** Names of every supplier, including ones switched off since. */
  supplierNames: Record<string, string>;
  ingredients: Ingredient[];
  names: IngredientNames;
  /** Orders that are Sent or Part received. */
  openOrders: OrderRow[];
  /** The last 20 goods receipts, newest first. */
  receipts: ReceiptRow[];
  /** The payments made on those receipts, by receipt id, oldest first. */
  payments: Record<string, PaymentRow[]>;
  currency: string;
  country: string;
  today: string;
  /** Opened from an order's "Receive" button. */
  initialPo: string | null;
  canTill: boolean;
  /** The restaurant claims input tax on purchases (Settings). */
  claimTax: boolean;
  /** The person may change that setting. */
  canSetClaim: boolean;
  /** Agreed prices in force today: supplier id → ingredient id → rate. */
  agreedRates: Record<string, Record<string, number>>;
  /** May enter an earlier receiving date. */
  canBackdate: boolean;
  backdateDays: number;
  /** Goods may be received without a purchase order. */
  directReceiving: boolean;
}) {
  const { pending, msg, setMsg, run } = useRun();
  const m = (n: number) => money(n, currency);
  const methods = payMethods(country);
  const only = suppliers.length === 1 ? suppliers[0].id : "";
  // An order can only be received for a supplier that is still active.
  const startOrder = initialPo ? openOrders.find((o) => o.id === initialPo && suppliers.some((s) => s.id === o.supplier_id)) : undefined;

  const [supplierId, setSupplierId] = useState(startOrder?.supplier_id ?? only);
  const [poId, setPoId] = useState(startOrder?.id ?? "");
  const [lines, setLines] = useState<LineDraft[]>(() => {
    const rest = startOrder ? remainingLines(startOrder) : [];
    return rest.length > 0 ? rest : [{ ...BLANK_LINE }];
  });
  const [receivedOn, setReceivedOn] = useState("");
  const [billNo, setBillNo] = useState("");
  const [billDate, setBillDate] = useState("");
  const [tax, setTax] = useState("");
  const [other, setOther] = useState("");
  const [receiptType, setReceiptType] = useState("purchase");
  const [distribute, setDistribute] = useState(false);
  const [paid, setPaid] = useState<Paid>("no");
  const [method, setMethod] = useState<PayMethod>("cash");
  const [reference, setReference] = useState("");
  const [amount, setAmount] = useState("");
  const [fromTill, setFromTill] = useState(false);
  // One reference per delivery, tied to what was sent: the very same delivery tried again keeps it
  // (so it is saved once); once anything on the form is changed, the next save gets a new one.
  const sent = useRef<SentRef | null>(null);
  const [stale, setStale] = useState(!!initialPo && !startOrder);

  // Below the form: pay or cancel one of the recent receipts.
  const [payId, setPayId] = useState<string | null>(null);
  const [cancelId, setCancelId] = useState<string | null>(null);
  const [returnId, setReturnId] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [listMsg, setListMsg] = useState<Note>(null);
  const list = useRun();

  const supplierOrders = openOrders.filter((o) => o.supplier_id === supplierId);
  const goods = linesCents(lines);
  const taxC = amountCents(tax);
  const otherC = amountCents(other);
  const lineTax = linesTaxCents(lines);
  const total = goods + lineTax + (taxC ?? 0) + (otherC ?? 0);

  function chooseSupplier(id: string) {
    setSupplierId(id);
    setStale(false);
    if (poId && openOrders.find((o) => o.id === poId)?.supplier_id !== id) {
      // The lines came from another supplier's order: start again.
      setPoId("");
      setLines([{ ...BLANK_LINE }]);
    }
  }

  function chooseOrder(id: string) {
    setPoId(id);
    const o = openOrders.find((x) => x.id === id);
    if (!o) return;
    const rest = remainingLines(o);
    setLines(rest.length > 0 ? rest : [{ ...BLANK_LINE }]);
  }

  function save() {
    if (!supplierId) return setMsg({ ok: false, text: "Choose a supplier." });
    const checked = checkLines(lines, names);
    if (!checked.ok) return setMsg({ ok: false, text: checked.error });
    if (taxC === null || otherC === null) return setMsg({ ok: false, text: "Tax and other charges must be numbers of zero or more." });
    if (billDate && billDate > today) return setMsg({ ok: false, text: "The supplier's bill date cannot be in the future." });
    let partC = 0;
    if (paid === "part") {
      const a = amountCents(amount);
      if (a === null || a <= 0) return setMsg({ ok: false, text: "Enter the amount paid." });
      if (a > total) return setMsg({ ok: false, text: "The amount paid cannot be more than the total." });
      partC = a;
    }
    const payload = {
      supplierId,
      purchaseOrderId: poId || null,
      lines: checked.lines,
      billNo,
      billDate,
      tax: taxC / 100,
      other: otherC / 100,
      paid,
      amount: partC / 100,
      method,
      reference,
      fromTill: method === "cash" && fromTill,
      receivedOn: canBackdate ? receivedOn : "",
      receiptType,
      distribute: distribute && (otherC ?? 0) > 0,
    };
    const mine = refFor(sent.current, payload);
    sent.current = mine;
    run(
      () => receiveGoods({ ...payload, clientRef: mine.ref }),
      (r) => {
        // Either way this reference is used up: the next save is a new delivery.
        sent.current = null;
        if (r.repeat && Math.round(r.total * 100) !== total) {
          // Should not happen now that the reference follows what was sent. Kept as a last check: never clear a form that was not saved.
          return {
            ok: false,
            text: `${r.number} was already saved from this screen earlier (total ${m(r.total)}). What is on the screen now is different and has NOT been saved. If it is another delivery, tap Save again. If it is the same delivery, clear the lines instead.`,
          };
        }
        setSupplierId(only);
        setPoId("");
        setLines([{ ...BLANK_LINE }]);
        setBillNo("");
        setBillDate("");
        setTax("");
        setOther("");
        setPaid("no");
        setReference("");
        setAmount("");
        setFromTill(false);
        setStale(false);
        const owes = r.balance > 0 ? `${m(r.balance)} is still owed (see the To pay tab).` : "Nothing is owed on it.";
        return r.repeat ? `This delivery was already saved as ${r.number}, total ${m(r.total)}. ${owes}` : `Saved as ${r.number}, total ${m(r.total)}. The goods are now in stock. ${owes}`;
      },
      "Could not reach the server. Check the connection and tap Save again without changing anything — the delivery will not be saved twice. If you need to change it, look in the list below first in case it was saved.",
    );
  }

  return (
    <div className="space-y-4">
      {suppliers.length === 0 ? (
        <AddSupplierFirst />
      ) : (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Goods that have arrived</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Saving adds the quantities to stock and updates each ingredient&rsquo;s cost.
          </p>
          {stale && (
            <p className="mt-2 rounded-lg px-3 py-2 text-sm" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              That order is not open for receiving (it may already be received or cancelled, or its supplier is not active). You can still receive goods without an order.
            </p>
          )}

          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <Field label="Supplier">
              <select className="field h-10 text-sm" value={supplierId} onChange={(e) => chooseSupplier(e.target.value)} disabled={pending}>
                <option value="">Choose a supplier…</option>
                {suppliers.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Against order" hint="(optional)">
              <select className="field h-10 text-sm" value={poId} onChange={(e) => chooseOrder(e.target.value)} disabled={pending || !supplierId || supplierOrders.length === 0}>
                <option value="">{!supplierId ? "Choose the supplier first" : supplierOrders.length === 0 ? "No open orders for this supplier" : "No order"}</option>
                {supplierOrders.map((o) => (
                  <option key={o.id} value={o.id}>
                    {o.number} · {dayLabel(o.date)} · {m(o.total)}
                  </option>
                ))}
              </select>
            </Field>
          </div>

          <div className="mt-4">
            <LineEditor lines={lines} onChange={setLines} ingredients={ingredients} names={names} currency={currency} qtyLabel="Quantity received" totalLabel="Goods" showTax agreed={agreedRates[supplierId]} disabled={pending} />
            {lineTax > 0 && (
              <p className="mt-2 text-right text-sm" style={{ color: "var(--color-ink-3)" }}>
                Tax on the lines: <b className="tabular-nums">{m(lineTax / 100)}</b>
              </p>
            )}
            <ClaimBox claimTax={claimTax} canSet={canSetClaim} />
          </div>

          <div className="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {canBackdate && (
              <Field label="Received on" hint="(blank = today)">
                <input className="field h-10 text-sm" type="date" max={today} min={addDays(today, -backdateDays)} value={receivedOn} onChange={(e) => setReceivedOn(e.target.value)} disabled={pending} />
              </Field>
            )}
            <Field label="Supplier's bill number" hint="(optional)">
              <input className="field h-10 text-sm" value={billNo} onChange={(e) => setBillNo(e.target.value)} maxLength={40} disabled={pending} />
            </Field>
            <Field label="Bill date" hint="(optional)">
              <input className="field h-10 text-sm" type="date" max={today} value={billDate} onChange={(e) => setBillDate(e.target.value)} disabled={pending} />
            </Field>
            <Field label="Other tax on the bill" hint="(not per line, optional)">
              <input className="field h-10 text-sm" inputMode="decimal" placeholder="0.00" value={tax} onChange={(e) => setTax(e.target.value)} disabled={pending} />
            </Field>
            <Field label="Other charges" hint="(delivery, loading…)">
              <input className="field h-10 text-sm" inputMode="decimal" placeholder="0.00" value={other} onChange={(e) => setOther(e.target.value)} disabled={pending} />
            </Field>
            <Field label="Receipt type">
              <select className="field h-10 text-sm" value={receiptType} onChange={(e) => setReceiptType(e.target.value)} disabled={pending}>
                <option value="purchase">Purchase</option>
                <option value="sample">Free sample</option>
                <option value="replacement">Replacement</option>
                <option value="transfer_in">Transfer in</option>
              </select>
            </Field>
            <label className="flex items-start gap-2 self-end pb-2 text-xs sm:col-span-2" style={{ color: "var(--color-ink-2)" }}>
              <input type="checkbox" className="mt-0.5 h-4 w-4" checked={distribute} onChange={(e) => setDistribute(e.target.checked)} disabled={pending} />
              <span>Add the other charges to the stock cost of these items, in proportion to their value.</span>
            </label>
          </div>

          <div className="mt-4 flex items-baseline justify-between rounded-2xl px-4 py-3" style={{ background: "var(--color-brand-soft)" }} aria-live="polite">
            <span className="text-sm font-bold">Total to pay the supplier</span>
            <span className="font-display text-2xl font-bold tabular-nums">{m(total / 100)}</span>
          </div>

          <fieldset className="mt-4">
            <legend className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-2)" }}>
              Paid now?
            </legend>
            <div className="flex flex-wrap gap-1.5">
              {PAID.map(([k, label]) => (
                <label
                  key={k}
                  className="inline-flex min-h-10 cursor-pointer items-center rounded-full border px-4 text-sm font-semibold focus-within:outline-2 focus-within:outline-offset-2"
                  style={{ borderColor: paid === k ? "var(--color-brand)" : "var(--color-line)", background: paid === k ? "var(--color-brand)" : "transparent", color: paid === k ? "#fff" : "var(--color-ink-2)" }}
                >
                  <input type="radio" name="paid-now" className="sr-only" checked={paid === k} onChange={() => setPaid(k)} disabled={pending} />
                  {label}
                </label>
              ))}
            </div>
          </fieldset>

          {paid !== "no" && (
            <div className="mt-3 grid gap-3 sm:grid-cols-3">
              {paid === "part" && (
                <Field label="Amount paid now">
                  <input className="field h-10 text-sm" inputMode="decimal" placeholder="0.00" value={amount} onChange={(e) => setAmount(e.target.value)} disabled={pending} />
                </Field>
              )}
              <Field label="Paid by">
                <select className="field h-10 text-sm" value={method} onChange={(e) => setMethod(e.target.value as PayMethod)} disabled={pending}>
                  {methods.map(([k, label]) => (
                    <option key={k} value={k}>
                      {label}
                    </option>
                  ))}
                </select>
              </Field>
              <Field label="Reference" hint="(optional)">
                <input className="field h-10 text-sm" placeholder="Cheque or transfer number" value={reference} onChange={(e) => setReference(e.target.value)} maxLength={60} disabled={pending} />
              </Field>
              {method === "cash" && canTill && (
                <label className="flex min-h-10 items-center gap-2 text-sm sm:col-span-3">
                  <input type="checkbox" className="h-5 w-5" checked={fromTill} onChange={(e) => setFromTill(e.target.checked)} disabled={pending} />
                  Paid from the till (records cash out of the drawer)
                </label>
              )}
            </div>
          )}

          <div className="mt-4 space-y-2">
            <Msg msg={msg} />
            <button type="button" className="btn btn-primary px-5 text-sm" onClick={save} disabled={pending}>
              {pending ? "Saving…" : "Save and add to stock"}
            </button>
          </div>
        </section>
      )}

      <section>
        <h2 className="mb-2 text-sm font-bold">Last deliveries received</h2>
        <div className="space-y-2">
          <Msg msg={listMsg ?? (list.msg?.ok ? list.msg : null)} />
        </div>
        <div className="card mt-2">
          {receipts.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              Nothing received yet.
            </p>
          ) : (
            <ul>
              {receipts.map((r, i) => {
                const supplier = supplierNames[r.supplier_id] ?? "Supplier";
                const busy = pending || list.pending;
                return (
                  <li key={r.id} className="px-4 py-3" style={i > 0 ? { borderTop: "1px solid var(--color-line)" } : undefined}>
                    <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
                      <div className="min-w-0">
                        <span className="font-semibold">{r.number}</span>{" "}
                        {r.cancelled ? (
                          <Badge label="Cancelled" bg="var(--color-bad-soft)" fg="var(--color-bad)" />
                        ) : r.owed > 0 ? (
                          <Badge label={`Owed ${m(r.owed)}`} bg="var(--color-warn-soft)" fg="var(--color-warn)" />
                        ) : (
                          <Badge label="Paid" bg="var(--color-ok-soft)" fg="var(--color-ok)" />
                        )}
                        <div className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                          {supplier} · {dayLabel(r.received_on)}
                          {r.bill_no ? ` · bill ${r.bill_no}` : ""}
                          {r.returned > 0 ? ` · ${m(r.returned)} returned` : ""}
                        </div>
                        {r.cancelled && r.cancel_reason && (
                          <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                            Reason: {r.cancel_reason}
                          </div>
                        )}
                      </div>
                      <div className="text-base font-bold tabular-nums" style={r.cancelled ? { textDecoration: "line-through", color: "var(--color-ink-3)" } : undefined}>
                        {m(r.total)}
                      </div>
                    </div>

                    {!r.cancelled && (r.owed > 0 || r.paid === 0 || r.returnable.length > 0) && payId !== r.id && cancelId !== r.id && returnId !== r.id && (
                      <div className="mt-2 flex flex-wrap gap-2">
                        {r.owed > 0 && (
                          <button
                            type="button"
                            className={rowBtn}
                            style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }}
                            onClick={() => {
                              setListMsg(null);
                              list.setMsg(null);
                              setCancelId(null);
                              setReturnId(null);
                              setPayId(r.id);
                            }}
                            disabled={busy}
                          >
                            Pay
                          </button>
                        )}
                        {r.returnable.length > 0 && r.owed > 0 && (
                          <button
                            type="button"
                            className={rowBtn}
                            style={lineStyle}
                            onClick={() => {
                              setListMsg(null);
                              list.setMsg(null);
                              setPayId(null);
                              setCancelId(null);
                              setReturnId(r.id);
                            }}
                            disabled={busy}
                          >
                            Return goods
                          </button>
                        )}
                      </div>
                    )}

                    {returnId === r.id && !r.cancelled && (
                      <ReturnForm
                        receipt={r}
                        supplier={supplier}
                        currency={currency}
                        onDone={(text) => {
                          setReturnId(null);
                          setListMsg({ ok: true, text });
                        }}
                        onClose={() => setReturnId(null)}
                      />
                    )}

                    {payId === r.id && !r.cancelled && r.owed > 0 && (
                      <PayForm
                        receipt={{ id: r.id, number: r.number, supplier, owed: r.owed }}
                        currency={currency}
                        country={country}
                        today={today}
                        canTill={canTill}
                        onDone={(text) => {
                          setPayId(null);
                          setListMsg({ ok: true, text });
                        }}
                        onClose={() => setPayId(null)}
                      />
                    )}

                    {!r.cancelled && (
                      <PaymentsList
                        payments={payments[r.id] ?? []}
                        currency={currency}
                        disabled={busy}
                        onDone={(text) => {
                          list.setMsg(null);
                          setListMsg({ ok: true, text });
                        }}
                      />
                    )}

                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
}
