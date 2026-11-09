"use client";

import Link from "next/link";
import { useRef, useState } from "react";
import { flushSync } from "react-dom";
import { money } from "@/lib/format";
import { savePurchaseOrder, setPurchaseOrderStatus } from "./actions";
import {
  BLANK_LINE,
  ORDER_STATUS,
  checkLines,
  dayLabel,
  fineCost,
  lineCents,
  lowStockLines,
  orderDraftLines,
  qtyText,
  type IngredientNames,
  type LineDraft,
  type OrderRow,
  type StockedIngredient,
  type SupplierRow,
} from "./helpers";
import { LineEditor } from "./line-editor";
import { AddSupplierFirst, Badge, Confirm, Field, Msg, lineStyle, rowBtn, useRun } from "./ui";

/** Also true when something is low but an order already sent covers it. */
const NOTHING_LOW = "Nothing needs ordering right now. Anything that is running low is already on an order you have sent.";

type Draft = { id: string | null; number: string | null; supplierId: string; expectedOn: string; notes: string; lines: LineDraft[] };

export function OrdersTab({
  orders,
  suppliers,
  ingredients,
  onOrder,
  names,
  currency,
  restaurant,
  outlet,
  autoLow,
  capped,
  agreedRates,
}: {
  orders: OrderRow[];
  /** Every supplier, active or not (old orders may be for one that was switched off). */
  suppliers: SupplierRow[];
  /** Active ingredients with what is in stock and the reorder level. */
  ingredients: StockedIngredient[];
  /** What is still to come on orders already sent at this outlet, by ingredient. */
  onOrder: Record<string, number>;
  names: IngredientNames;
  currency: string;
  restaurant: string;
  outlet: string;
  /** Opened from "Order low stock": start a new order already filled from the low-stock list. */
  autoLow: boolean;
  /** Only the newest orders are listed. */
  capped: boolean;
  /** Agreed prices in force today: supplier id → ingredient id → rate. */
  agreedRates: Record<string, Record<string, number>>;
}) {
  const { pending, msg, setMsg, run } = useRun();
  const m = (n: number) => money(n, currency);
  const active = suppliers.filter((s) => s.is_active);
  const supplierOf = (id: string) => suppliers.find((s) => s.id === id);
  const only = active.length === 1 ? active[0].id : "";

  const blank = (lines: LineDraft[]): Draft => ({ id: null, number: null, supplierId: only, expectedOn: "", notes: "", lines });
  const [form, setForm] = useState<Draft | null>(() => {
    if (!autoLow || active.length === 0) return null;
    const low = lowStockLines(ingredients, onOrder);
    return blank(low.length > 0 ? low : [{ ...BLANK_LINE }]);
  });
  const [lowNote, setLowNote] = useState<string | null>(() => {
    if (!autoLow || active.length === 0) return null;
    const n = lowStockLines(ingredients, onOrder).length;
    return n > 0 ? `${n} ingredient${n === 1 ? " is" : "s are"} running low. Check the quantities, choose the supplier, then save.` : NOTHING_LOW;
  });
  const upd = (patch: Partial<Draft>) => setForm((f) => (f ? { ...f, ...patch } : f));

  // The order shown as a sheet (to read, or to print).
  const [viewId, setViewId] = useState<string | null>(null);
  const sheet = useRef<HTMLDivElement>(null);
  const view = orders.find((o) => o.id === viewId) ?? null;
  const viewSupplier = view ? supplierOf(view.supplier_id) : undefined;

  function show(id: string, print: boolean) {
    // Put the sheet on the page first, so the printer has something to print.
    flushSync(() => setViewId(id));
    sheet.current?.scrollIntoView({ block: "start" });
    if (print) window.print();
  }

  function fillLow() {
    if (!form) return;
    const low = lowStockLines(ingredients, onOrder);
    const have = new Set(form.lines.map((l) => l.ingredient_id).filter(Boolean));
    const add = low.filter((l) => !have.has(l.ingredient_id));
    if (low.length === 0) return setLowNote(NOTHING_LOW);
    if (add.length === 0) return setLowNote("Everything that is running low is already on this order.");
    const kept = form.lines.filter((l) => l.ingredient_id || l.qty.trim() !== "");
    upd({ lines: [...kept, ...add] });
    setLowNote(`Added ${add.length} ingredient${add.length === 1 ? "" : "s"} that ${add.length === 1 ? "is" : "are"} running low. Check the quantities before you save.`);
  }

  function save(place: boolean) {
    if (!form) return;
    if (!form.supplierId) return setMsg({ ok: false, text: "Choose a supplier." });
    const checked = checkLines(form.lines, names);
    if (!checked.ok) return setMsg({ ok: false, text: checked.error });
    run(
      () => savePurchaseOrder({ id: form.id, supplierId: form.supplierId, expectedOn: form.expectedOn, notes: form.notes, lines: checked.lines, place }),
      () => {
        setForm(null);
        setLowNote(null);
      },
      // A new order has no request reference: if the first try did get through, saving again would make a second order.
      form.id ? undefined : "Could not reach the server, so it is not clear whether this order was saved. Check the Orders list below before you save it again, or you may end up with the same order twice.",
    );
  }

  function edit(o: OrderRow) {
    setMsg(null);
    setLowNote(null);
    setForm({ id: o.id, number: o.number, supplierId: o.supplier_id, expectedOn: o.expected_on ?? "", notes: o.notes ?? "", lines: o.lines.length > 0 ? orderDraftLines(o) : [{ ...BLANK_LINE }] });
    window.scrollTo({ top: 0 });
  }

  const formSupplier = form ? supplierOf(form.supplierId) : undefined;

  return (
    <div className="space-y-4">
      {!form && <Msg msg={msg} />}

      {active.length === 0 ? (
        <AddSupplierFirst />
      ) : form ? (
        <section className="card p-4">
          <h2 className="text-sm font-bold">{form.id ? `Edit order ${form.number ?? ""}` : "New order"}</h2>
          {lowNote && (
            <p className="mt-2 rounded-lg px-3 py-2 text-sm" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              {lowNote}
            </p>
          )}
          <div className="mt-3 grid gap-3 sm:grid-cols-3">
            <Field label="Supplier">
              <select className="field h-10 text-sm" value={form.supplierId} onChange={(e) => upd({ supplierId: e.target.value })} disabled={pending}>
                <option value="">Choose a supplier…</option>
                {formSupplier && !formSupplier.is_active && <option value={formSupplier.id}>{formSupplier.name} (not active)</option>}
                {active.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Expected on" hint="(optional)">
              <input className="field h-10 text-sm" type="date" value={form.expectedOn} onChange={(e) => upd({ expectedOn: e.target.value })} disabled={pending} />
            </Field>
            <Field label="Notes for the supplier" hint="(optional)">
              <input className="field h-10 text-sm" value={form.notes} onChange={(e) => upd({ notes: e.target.value })} maxLength={300} disabled={pending} />
            </Field>
          </div>

          <div className="mt-4">
            <LineEditor lines={form.lines} onChange={(lines) => upd({ lines })} ingredients={ingredients} names={names} currency={currency} totalLabel="Order total" agreed={agreedRates[form.supplierId]} disabled={pending} />
          </div>

          <div className="mt-3">
            <button type="button" className={rowBtn} style={lineStyle} onClick={fillLow} disabled={pending}>
              Fill from low stock
            </button>
          </div>

          <div className="mt-4">
            <Msg msg={msg} />
          </div>
          <div className="mt-3 flex flex-wrap gap-2">
            <button
              type="button"
              className="btn border px-4 text-sm"
              style={lineStyle}
              onClick={() => {
                setForm(null);
                setLowNote(null);
                setMsg(null);
              }}
              disabled={pending}
            >
              Close without saving
            </button>
            <button type="button" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }} onClick={() => save(false)} disabled={pending}>
              {pending ? "Saving…" : "Save as draft"}
            </button>
            <button type="button" className="btn btn-primary px-4 text-sm" onClick={() => save(true)} disabled={pending}>
              {pending ? "Saving…" : "Send order"}
            </button>
          </div>
          <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
            &ldquo;Send order&rdquo; marks the order as sent so it can be received later. It does not message the supplier: print it, or read it out on the phone. A sent order cannot be changed, only cancelled.
          </p>
        </section>
      ) : (
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            className="btn btn-primary px-4 text-sm"
            onClick={() => {
              setMsg(null);
              setLowNote(null);
              setForm(blank([{ ...BLANK_LINE }]));
            }}
          >
            + New order
          </button>
        </div>
      )}

      {view && (
        <section>
          {/* Printing shows this sheet and nothing else (same idea as a customer receipt). */}
          <style>{`
            @media print {
              body * { visibility: hidden !important; }
              #po-print, #po-print * { visibility: visible !important; }
              #po-print { position: absolute; left: 0; top: 0; width: 100%; border: 0 !important; box-shadow: none !important; }
              .no-print { display: none !important; }
            }
          `}</style>
          <div ref={sheet} id="po-print" className="card p-5 text-sm" style={{ background: "#fff", color: "#111" }}>
            <div className="flex flex-wrap items-start justify-between gap-3">
              <div>
                <div className="text-base font-bold">{restaurant}</div>
                <div>{outlet}</div>
              </div>
              <div className="text-right">
                <div className="text-base font-bold tracking-wide">PURCHASE ORDER</div>
                <div className="font-semibold">{view.number}</div>
                <div>Date: {dayLabel(view.date)}</div>
                {view.expected_on && <div>Expected: {dayLabel(view.expected_on)}</div>}
                {view.status === "draft" && <div className="font-bold">DRAFT — not sent yet</div>}
                {view.status === "cancelled" && <div className="font-bold">CANCELLED</div>}
              </div>
            </div>
            <div className="mt-4">
              <div className="text-xs font-semibold uppercase">To</div>
              <div className="font-bold">{viewSupplier?.name ?? "Supplier"}</div>
              {viewSupplier?.contact_person && <div>{viewSupplier.contact_person}</div>}
              {viewSupplier?.address && <div>{viewSupplier.address}</div>}
              {viewSupplier?.phone && <div>Tel {viewSupplier.phone}</div>}
            </div>
            <table className="mt-4 w-full">
              <thead>
                <tr style={{ borderBottom: "1px solid #999" }}>
                  <th className="py-1 pr-2 text-left text-xs font-semibold">#</th>
                  <th className="py-1 pr-2 text-left text-xs font-semibold">Item</th>
                  <th className="py-1 pr-2 text-right text-xs font-semibold">Quantity</th>
                  <th className="py-1 pr-2 text-right text-xs font-semibold">Cost per unit</th>
                  <th className="py-1 text-right text-xs font-semibold">Amount</th>
                </tr>
              </thead>
              <tbody>
                {view.lines.map((l, i) => {
                  const ing = names[l.ingredient_id];
                  const got = l.received_qty > 0 ? ` (received ${qtyText(l.received_qty)})` : "";
                  return (
                    <tr key={l.ingredient_id} style={{ borderBottom: "1px solid #ddd" }}>
                      <td className="py-1 pr-2 align-top">{i + 1}</td>
                      <td className="py-1 pr-2 align-top">{ing?.name ?? "Ingredient"}</td>
                      <td className="py-1 pr-2 text-right align-top tabular-nums">
                        {qtyText(l.qty)} {ing?.unit ?? ""}
                        {got && <span className="no-print">{got}</span>}
                      </td>
                      <td className="py-1 pr-2 text-right align-top tabular-nums">{fineCost(l.unit_cost) ? l.unit_cost : m(l.unit_cost)}</td>
                      <td className="py-1 text-right align-top tabular-nums">{m(lineCents(l.qty, l.unit_cost) / 100)}</td>
                    </tr>
                  );
                })}
              </tbody>
              <tfoot>
                <tr>
                  <td colSpan={4} className="py-2 pr-2 text-right font-bold">
                    Total
                  </td>
                  <td className="py-2 text-right font-bold tabular-nums">{m(view.total)}</td>
                </tr>
              </tfoot>
            </table>
            {view.notes && <p className="mt-2">Notes: {view.notes}</p>}
          </div>
          <div className="mt-2 flex flex-wrap gap-2">
            <button type="button" className="btn btn-primary px-4 text-sm" onClick={() => window.print()}>
              Print
            </button>
            <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={() => setViewId(null)}>
              Close
            </button>
          </div>
        </section>
      )}

      <section className="card">
        {orders.length === 0 ? (
          <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
            No purchase orders yet.
          </p>
        ) : (
          <ul>
            {orders.map((o, i) => {
              const st = ORDER_STATUS[o.status] ?? { label: o.status, bg: "var(--color-ground)", fg: "var(--color-ink-2)" };
              return (
                <li key={o.id} className="px-4 py-3" style={i > 0 ? { borderTop: "1px solid var(--color-line)" } : undefined}>
                  <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
                    <div className="min-w-0">
                      <button type="button" className="min-h-10 text-left font-semibold underline-offset-2 hover:underline" onClick={() => show(o.id, false)} aria-label={`Show order ${o.number}`}>
                        {o.number}
                      </button>{" "}
                      <Badge {...st} />
                      <div className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                        {supplierOf(o.supplier_id)?.name ?? "Supplier"} · {dayLabel(o.date)}
                        {o.expected_on && (o.status === "ordered" || o.status === "part_received" || o.status === "draft") ? ` · expected ${dayLabel(o.expected_on)}` : ""}
                      </div>
                    </div>
                    <div className="text-base font-bold tabular-nums">{m(o.total)}</div>
                  </div>
                  <div className="mt-2 flex flex-wrap items-center gap-2">
                    {o.status === "draft" && (
                      <>
                        <button type="button" className={rowBtn} style={lineStyle} onClick={() => edit(o)} disabled={pending || active.length === 0}>
                          Edit
                        </button>
                        <button type="button" className={rowBtn} style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }} onClick={() => run(() => setPurchaseOrderStatus(o.id, "order"))} disabled={pending}>
                          Send
                        </button>
                      </>
                    )}
                    {(o.status === "ordered" || o.status === "part_received") && (
                      <Link href={`/purchases?tab=receive&po=${o.id}`} className={rowBtn} style={{ borderColor: "var(--color-brand)", background: "var(--color-brand)", color: "#fff" }}>
                        Receive
                      </Link>
                    )}
                    {o.status === "part_received" && (
                      <Confirm
                        question={`Close ${o.number}? The rest will not be received on it.`}
                        yes="Yes, no more coming"
                        no="Keep open"
                        danger={false}
                        onYes={() => run(() => setPurchaseOrderStatus(o.id, "close"))}
                        disabled={pending}
                      >
                        No more coming
                      </Confirm>
                    )}
                    <button type="button" className={rowBtn} style={lineStyle} onClick={() => show(o.id, true)}>
                      Print
                    </button>
                    {(o.status === "draft" || o.status === "ordered") && (
                      <Confirm question={`Cancel order ${o.number}?`} yes="Yes, cancel it" no="Keep it" onYes={() => run(() => setPurchaseOrderStatus(o.id, "cancel"))} disabled={pending}>
                        Cancel
                      </Confirm>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
        {capped && (
          <p className="px-4 py-2 text-xs" style={{ borderTop: "1px solid var(--color-line)", color: "var(--color-ink-3)" }}>
            Showing the newest {orders.length} orders.
          </p>
        )}
      </section>
    </div>
  );
}
