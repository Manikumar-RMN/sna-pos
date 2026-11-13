"use client";

import { billRefLc } from "@/lib/format";
import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { moveItems, type MoveItemsResult } from "./move-item-actions";

export type MoveLine = { id: string; name: string; options: string | null; qty: number };
export type MoveTable = { id: string; number: string; busy: boolean };

/**
 * "Move item": choose what moves (all or part of a line) and the table it goes to. A table with an open bill gets the items added
 * to that bill; a free table gets a new bill. Prices and tax stay as they were; both bills are worked out again by the database.
 * Used inside BillActions (see docs/handover/WS-B/move-item-wiring.md). Refuses nothing itself: `blocked` is only the wording shown
 * when the bill has a payment, a discount or is complimentary, which the database also refuses.
 */
export function MoveItemPanel({
  orderId,
  billNumber,
  lines,
  tables,
  currentTableId,
  blocked = null,
  onMoved,
}: {
  orderId: string;
  billNumber: string;
  lines: MoveLine[];
  tables: MoveTable[];
  currentTableId: string | null;
  /** Why the items cannot move (payment / discount), or null. */
  blocked?: string | null;
  /** Called after a successful move. Without it the page is refreshed. */
  onMoved?: (result: Extract<MoveItemsResult, { ok: true }>) => void;
}) {
  const router = useRouter();
  const [qty, setQty] = useState<Record<string, number>>({});
  const [toTable, setToTable] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<Extract<MoveItemsResult, { ok: true }> | null>(null);
  const [approval, setApproval] = useState<null | { permission: string; retry: () => void }>(null);
  const [pending, start] = useTransition();
  // The same request id while the same move is retried (dropped internet), a new one when what is asked changes.
  const ref = useRef<{ key: string; id: string } | null>(null);

  const total = lines.reduce((s, l) => s + l.qty, 0);
  const chosen = Object.values(qty).reduce((s, q) => s + q, 0);
  const target = tables.find((t) => t.id === toTable) ?? null;
  const all = chosen >= total;

  function submit() {
    setError(null);
    setNotice(null);
    const items = Object.entries(qty)
      .filter(([, q]) => q > 0)
      .map(([order_item_id, q]) => ({ order_item_id, qty: q }))
      .sort((a, b) => a.order_item_id.localeCompare(b.order_item_id));
    const key = JSON.stringify([items, toTable]);
    if (ref.current?.key !== key) ref.current = { key, id: crypto.randomUUID() };
    const clientRef = ref.current.id;
    start(async () => {
      let res: MoveItemsResult;
      try {
        res = await moveItems({ orderId, toTableId: toTable, items, clientRef });
      } catch {
        // No reply from the server. The same request id makes pressing the button again safe.
        return setError("The internet dropped while moving. Press the button again; the items will not be moved twice.");
      }
      if (!res.ok) {
        const need = neededRight(res.error);
        if (need) setApproval({ permission: need, retry: submit });
        return setError(cleanMessage(res.error));
      }
      ref.current = null;
      setQty({});
      setToTable("");
      setNotice(res);
      if (onMoved) onMoved(res);
      else router.refresh();
    });
  }

  if (blocked) {
    return (
      <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
        {blocked}
      </p>
    );
  }

  return (
    <div>
      {approval && (
        <ApprovalPrompt
          permission={approval.permission}
          onCancel={() => setApproval(null)}
          onApproved={() => {
            const retry = approval.retry;
            setApproval(null);
            retry();
          }}
        />
      )}
      <p className="mb-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Choose the items and the table they go to. They keep their price and tax; both bills are worked out again. Leave at least one item on {billRefLc(billNumber)}.
      </p>
      <ul className="space-y-1.5">
        {lines.map((l) => {
          const q = qty[l.id] ?? 0;
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
              <div className="flex items-center gap-1">
                <button
                  type="button"
                  className="grid h-8 w-8 place-items-center rounded-md border"
                  style={{ borderColor: "var(--color-line)" }}
                  onClick={() => setQty({ ...qty, [l.id]: Math.max(0, q - 1) })}
                  disabled={q <= 0}
                  aria-label={`One less ${l.name} to move`}
                >
                  −
                </button>
                <span className="w-5 text-center text-sm font-semibold">{q}</span>
                <button
                  type="button"
                  className="grid h-8 w-8 place-items-center rounded-md border"
                  style={{ borderColor: "var(--color-line)" }}
                  onClick={() => setQty({ ...qty, [l.id]: Math.min(l.qty, q + 1) })}
                  disabled={q >= l.qty}
                  aria-label={`One more ${l.name} to move`}
                >
                  +
                </button>
              </div>
              <span className="w-8 text-right text-xs" style={{ color: "var(--color-ink-3)" }}>
                of {l.qty}
              </span>
            </li>
          );
        })}
      </ul>

      <div className="mt-3 text-xs font-medium" style={{ color: "var(--color-ink-2)" }} id={`move-to-${orderId}`}>
        Move to table
      </div>
      {tables.filter((t) => t.id !== currentTableId).length === 0 ? (
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
          No other table is set up. Add tables in Settings.
        </p>
      ) : (
        <div className="mt-1.5 flex flex-wrap gap-1.5" role="group" aria-labelledby={`move-to-${orderId}`}>
          {tables
            .filter((t) => t.id !== currentTableId)
            .map((t) => (
              <button
                key={t.id}
                type="button"
                onClick={() => setToTable(t.id)}
                aria-pressed={toTable === t.id}
                aria-label={t.busy ? `T${t.number}, has an open bill` : `T${t.number}, free`}
                className="rounded-md border px-2.5 py-1 text-xs font-semibold"
                style={{
                  borderColor: toTable === t.id ? "var(--color-brand)" : t.busy ? "var(--color-brand)" : "var(--color-line)",
                  borderStyle: t.busy && toTable !== t.id ? "dashed" : "solid",
                  background: toTable === t.id ? "var(--color-brand)" : "transparent",
                  color: toTable === t.id ? "#fff" : "var(--color-ink-2)",
                }}
              >
                T{t.number}
                {t.busy ? " ●" : ""}
              </button>
            ))}
        </div>
      )}
      <p className="mt-1.5 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
        ● has an open bill: the items are added to it. A free table gets a new bill.
      </p>

      {error && (
        <p className="mt-2 text-xs" role="alert" style={{ color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      {notice && (
        <p className="mt-2 text-xs" role="status" style={{ color: "var(--color-ok)" }}>
          {notice.message}
        </p>
      )}
      <button className="btn btn-primary mt-3 w-full text-sm" disabled={pending || chosen === 0 || all || !toTable} onClick={submit}>
        {pending ? "Moving…" : chosen === 0 ? "Move items" : `Move ${chosen} to ${target ? `T${target.number}` : "a table"}`}
      </button>
      {all && chosen > 0 && (
        <p className="mt-1.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
          To move everything, use Move table (or Merge bills).
        </p>
      )}
    </div>
  );
}
