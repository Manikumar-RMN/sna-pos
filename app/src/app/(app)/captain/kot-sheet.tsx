"use client";

import { useCallback, useEffect, useState, useTransition } from "react";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { logPrint } from "../bills/log-print";
import { loadKotPrintInfo } from "../pos/kot/[orderId]/actions";
import { useSlipPrinter, type KotSlip } from "../pos/kot/[orderId]/kot-print";
import { cancelKot, cancelKotItem, loadBillKots, modifyKotItem, type Kot, type KotItem } from "./actions";

type Edit =
  | { kind: "item-cancel"; item: KotItem; qty: string; reason: string }
  | { kind: "item-change"; item: KotItem; qty: string; note: string; reason: string }
  | { kind: "kot-cancel"; kot: Kot; reason: string };

const statusText: Record<string, string> = { new: "New", preparing: "Cooking", ready: "Ready", served: "Served", cancelled: "Cancelled" };

/**
 * What was already sent to the kitchen for one bill. The waiter can cancel a whole KOT or one item (a reason is
 * needed, no manager PIN), or change an item's quantity or note. The kitchen screen shows the change at once.
 */
export function KotSheet({ orderId, billNumber, onClose, onChanged }: { orderId: string; billNumber: string | null; onClose: () => void; onChanged: () => void }) {
  const [kots, setKots] = useState<Kot[] | null>(null);
  const [edit, setEdit] = useState<Edit | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [pending, start] = useTransition();
  // Reprint: the manager PIN prompt (for a role without the reprint right) and the ticket being reprinted.
  const [pinFor, setPinFor] = useState<Kot | null>(null);
  const [reprinting, setReprinting] = useState<string | null>(null);
  const printer = useSlipPrinter();

  const load = useCallback(async () => {
    const r = await loadBillKots(orderId);
    if (r.ok) setKots(r.kots);
    else setError(r.error);
  }, [orderId]);
  useEffect(() => {
    load();
  }, [load]);

  function done(message: string) {
    setEdit(null);
    setError(null);
    setNote(message);
    onChanged();
    load();
  }

  function submit() {
    if (!edit) return;
    setError(null);
    start(async () => {
      if (edit.kind === "kot-cancel") {
        const r = await cancelKot({ orderId, ticketId: edit.kot.id, reason: edit.reason });
        return r.ok ? done(r.message) : setError(r.error);
      }
      if (edit.kind === "item-cancel") {
        const r = await cancelKotItem({ orderId, itemId: edit.item.id, qty: Number(edit.qty), reason: edit.reason });
        return r.ok ? done(r.message) : setError(r.error);
      }
      const newQty = Number(edit.qty);
      const qtyChanged = Number.isFinite(newQty) && newQty !== edit.item.qty;
      const noteChanged = edit.note.trim() !== (edit.item.note ?? "").trim();
      if (!qtyChanged && !noteChanged) return setError("Change the quantity or the note first.");
      if (qtyChanged && !(newQty > 0)) return setError("To remove the item, use Cancel.");
      if (qtyChanged && newQty < edit.item.qty && edit.reason.trim().length < 3) return setError("Write a short reason for reducing the quantity.");
      const r = await modifyKotItem({ orderId, itemId: edit.item.id, qty: qtyChanged ? newQty : null, note: noteChanged ? edit.note.trim() : null, reason: edit.reason });
      return r.ok ? done(r.message) : setError(r.error);
    });
  }

  /**
   * Prints the ticket again. The reprint is logged first (log_print, migration 135): it needs the "Reprint bills and KOTs" right
   * or a manager PIN, and the ticket is printed only once the log is written.
   */
  async function reprintKot(k: Kot) {
    setNote(null);
    setError(null);
    setReprinting(k.id);
    try {
      const pi = await loadKotPrintInfo(orderId);
      if (!pi.ok) return setError(pi.error);
      const res = await logPrint({ kind: "kot", orderId, ticketIds: [k.id] });
      if (!res.ok) {
        if (neededRight(res.error) === "order.reprint") return setPinFor(k);
        return setError(cleanMessage(res.error));
      }
      const slip: KotSlip = {
        id: k.id,
        number: k.number,
        station: k.station,
        createdAt: k.createdAt,
        printed: true,
        items: k.items.map((i) => ({ name: i.name, local: null, qty: i.qty, note: i.note, cancelled: i.cancelled })),
      };
      await printer.print([slip], pi.info);
      setNote(`KOT ${k.number} printed again.`);
    } catch {
      setError("Could not reach the server. Check the internet and try again.");
    } finally {
      setReprinting(null);
    }
  }

  const reduce = edit?.kind === "item-change" && Number(edit.qty) < edit.item.qty;

  return (
    <div className="fixed inset-0 z-50 grid items-end sm:place-items-center sm:p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="card max-h-[88vh] w-full max-w-md overflow-y-auto rounded-b-none p-5 sm:rounded-b-2xl" style={{ background: "var(--color-surface)" }} role="dialog" aria-label="Sent to the kitchen">
        <div className="flex items-start justify-between gap-2">
          <div>
            <h3 className="text-lg font-bold">Sent to the kitchen</h3>
            {billNumber && (
              <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                Bill {billNumber}
              </p>
            )}
          </div>
          <button className="btn" style={{ flex: "none", minHeight: 36, padding: "0 12px" }} onClick={onClose} aria-label="Close">
            ✕
          </button>
        </div>

        {note && (
          <p role="status" className="mt-3 rounded-lg px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}>
            {note}
          </p>
        )}
        {error && (
          <p role="alert" className="mt-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
            {error}
          </p>
        )}

        {kots === null && !error && <p className="mt-4 text-sm">Loading…</p>}
        {kots && kots.length === 0 && (
          <p className="mt-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Nothing has been sent to the kitchen on this bill.
          </p>
        )}

        <div className="mt-3 space-y-3">
          {(kots ?? []).map((k) => {
            const open = k.status === "new" || k.status === "preparing";
            const canCancel = open || k.status === "ready";
            const items = k.items.filter((i) => !i.cancelled);
            return (
              <div key={k.id} className="rounded-xl border p-3" style={{ borderColor: "var(--color-line)", opacity: k.status === "cancelled" ? 0.6 : 1 }}>
                <div className="flex items-center justify-between gap-2">
                  <div className="min-w-0 text-sm font-bold">
                    {k.number}
                    <span className="ml-2 text-[11px] font-normal" style={{ color: "var(--color-ink-3)" }}>
                      {k.station}
                    </span>
                  </div>
                  <span
                    className="shrink-0 rounded px-1.5 py-0.5 text-[11px] font-bold"
                    style={{
                      background: k.status === "cancelled" ? "var(--color-bad-soft)" : k.status === "ready" ? "var(--color-ok-soft)" : "var(--color-brand-soft)",
                      color: k.status === "cancelled" ? "var(--color-bad)" : k.status === "ready" ? "var(--color-ok)" : "var(--color-brand)",
                    }}
                  >
                    {statusText[k.status] ?? k.status}
                  </span>
                </div>
                {k.status === "cancelled" && k.cancelReason && (
                  <p className="mt-1 text-xs" style={{ color: "var(--color-bad)" }}>
                    Cancelled: {k.cancelReason}
                  </p>
                )}
                <ul className="mt-2 space-y-2">
                  {k.items.map((i) => (
                    <li key={i.id} className="text-sm" style={i.cancelled ? { textDecoration: "line-through", color: "var(--color-ink-3)" } : undefined}>
                      <div className="flex items-center gap-2">
                        <span className="min-w-0 flex-1">
                          <b className="tabular-nums">{i.qty}×</b> {i.name}
                        </span>
                        {!i.cancelled && k.status !== "cancelled" && (
                          <>
                            {open && (
                              <button
                                className="rounded-lg border px-2.5 py-1 text-xs font-semibold"
                                style={{ borderColor: "var(--color-line)" }}
                                onClick={() => {
                                  setNote(null);
                                  setError(null);
                                  setEdit({ kind: "item-change", item: i, qty: String(i.qty), note: i.note ?? "", reason: "" });
                                }}
                              >
                                Change
                              </button>
                            )}
                            {canCancel && (
                              <button
                                className="rounded-lg border px-2.5 py-1 text-xs font-semibold"
                                style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }}
                                onClick={() => {
                                  setNote(null);
                                  setError(null);
                                  setEdit({ kind: "item-cancel", item: i, qty: String(i.qty), reason: "" });
                                }}
                              >
                                Cancel
                              </button>
                            )}
                          </>
                        )}
                      </div>
                      {i.note && !i.cancelled && (
                        <div className="text-xs" style={{ color: "var(--color-warn)" }}>
                          {i.note}
                        </div>
                      )}
                      {i.changeText && !i.cancelled && (
                        <div className="text-[11px] font-semibold" style={{ color: "var(--color-ink-3)" }}>
                          {i.changeText}
                        </div>
                      )}
                    </li>
                  ))}
                </ul>
                {k.status !== "cancelled" && items.length > 0 && (
                  <button
                    className="mt-3 w-full rounded-lg border py-2 text-xs font-bold"
                    style={{ borderColor: "var(--color-line)" }}
                    disabled={reprinting !== null}
                    onClick={() => void reprintKot(k)}
                  >
                    {reprinting === k.id ? "Printing…" : "Reprint KOT"}
                  </button>
                )}
                {canCancel && items.length > 0 && (
                  <button
                    className="mt-3 w-full rounded-lg border py-2 text-xs font-bold"
                    style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }}
                    onClick={() => {
                      setNote(null);
                      setError(null);
                      setEdit({ kind: "kot-cancel", kot: k, reason: "" });
                    }}
                  >
                    Cancel this whole KOT
                  </button>
                )}
                {k.status === "served" && (
                  <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    Already served. A manager can cancel it on the bill.
                  </p>
                )}
                {k.status === "ready" && (
                  <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    The food is ready, so it cannot be changed, only cancelled.
                  </p>
                )}
              </div>
            );
          })}
        </div>

        {pinFor && (
          <ApprovalPrompt
            permission="order.reprint"
            onCancel={() => setPinFor(null)}
            onApproved={() => {
              const k = pinFor;
              setPinFor(null);
              void reprintKot(k);
            }}
          />
        )}
        {printer.node}

        {edit && (
          <div className="mt-4 rounded-xl border-2 p-3" style={{ borderColor: edit.kind === "item-change" ? "var(--color-brand)" : "var(--color-bad)" }}>
            <div className="text-sm font-bold">
              {edit.kind === "kot-cancel" && `Cancel KOT ${edit.kot.number}`}
              {edit.kind === "item-cancel" && `Cancel ${edit.item.name}`}
              {edit.kind === "item-change" && `Change ${edit.item.name}`}
            </div>
            {(edit.kind === "item-cancel" || edit.kind === "item-change") && (
              <label className="mt-2 flex items-center gap-2 text-xs font-semibold">
                {edit.kind === "item-cancel" ? "How many to cancel" : "New quantity"}
                <input
                  className="field h-10 w-20 text-center text-sm"
                  inputMode={edit.item.byWeight ? "decimal" : "numeric"}
                  value={edit.qty}
                  onChange={(e) => setEdit({ ...edit, qty: e.target.value })}
                />
              </label>
            )}
            {edit.kind === "item-change" && (
              <input
                className="field mt-2 h-10 text-sm"
                placeholder="Note for the kitchen (no onion, less spicy)"
                maxLength={200}
                value={edit.note}
                onChange={(e) => setEdit({ ...edit, note: e.target.value })}
              />
            )}
            {(edit.kind !== "item-change" || reduce) && (
              <input
                className="field mt-2 h-10 text-sm"
                placeholder="Reason (required)"
                maxLength={200}
                value={edit.reason}
                onChange={(e) => setEdit({ ...edit, reason: e.target.value })}
              />
            )}
            {edit.kind === "item-change" && Number(edit.qty) > edit.item.qty && (
              <p className="mt-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                The extra {Number(edit.qty) - edit.item.qty} goes to the kitchen as a new KOT.
              </p>
            )}
            <div className="mt-3 flex gap-2">
              <button className="btn" style={{ flex: "none", padding: "0 14px" }} onClick={() => setEdit(null)} disabled={pending}>
                Back
              </button>
              <button className="btn btn-primary" style={{ flex: 1 }} onClick={submit} disabled={pending}>
                {pending ? "Saving…" : edit.kind === "item-change" ? "Save change" : "Confirm cancel"}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
