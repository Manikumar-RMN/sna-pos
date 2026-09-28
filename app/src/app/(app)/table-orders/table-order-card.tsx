"use client";

import { useEffect, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { acceptTableOrder, rejectTableOrder } from "./actions";

export type TableOrderView = {
  id: string;
  table: string;
  guest: string | null;
  note: string | null;
  total: string;
  at: string;
  status: "pending" | "accepted" | "rejected";
  reason: string | null;
  lines: { qty: number; name: string; options: string }[];
};

export function AutoRefresh({ seconds }: { seconds: number }) {
  const router = useRouter();
  useEffect(() => {
    const t = setInterval(() => router.refresh(), seconds * 1000);
    return () => clearInterval(t);
  }, [router, seconds]);
  return null;
}

export function TableOrderCard({ order, canAct }: { order: TableOrderView; canAct: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [rejecting, setRejecting] = useState(false);
  const [reason, setReason] = useState("");

  return (
    <div className="card p-4">
      <div className="mb-2 flex items-center justify-between">
        <div className="text-lg font-bold">Table {order.table}</div>
        <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>{order.at}</div>
      </div>
      {order.guest && <div className="mb-1 text-sm">Guest: {order.guest}</div>}
      <ul className="mb-2 space-y-0.5 text-sm">
        {order.lines.map((l, i) => (
          <li key={i}>
            <b className="tabular-nums">{l.qty}×</b> {l.name}
            {l.options && <span style={{ color: "var(--color-ink-3)" }}> — {l.options}</span>}
          </li>
        ))}
      </ul>
      {order.note && (
        <div className="mb-2 text-sm font-semibold" style={{ color: "var(--color-warn)" }}>
          Note: {order.note}
        </div>
      )}
      <div className="mb-3 text-sm">About {order.total} incl. tax</div>
      {order.status !== "pending" && (
        <div className="text-sm font-bold" style={{ color: order.status === "accepted" ? "var(--color-ok)" : "var(--color-bad)" }}>
          {order.status === "accepted" ? "Accepted" : `Rejected${order.reason ? `: ${order.reason}` : ""}`}
        </div>
      )}
      {error && <p role="alert" className="mb-2 text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{error}</p>}
      {order.status === "pending" && canAct && !rejecting && (
        <div className="flex gap-2">
          <button
            className="btn btn-pay flex-1"
            disabled={pending}
            onClick={() =>
              start(async () => {
                const r = await acceptTableOrder(order.id);
                if (!r.ok) return setError(r.error);
                router.refresh();
              })
            }
          >
            {pending ? "…" : "Accept & send to kitchen"}
          </button>
          <button className="btn border" style={{ borderColor: "var(--color-line)" }} onClick={() => setRejecting(true)}>
            Reject
          </button>
        </div>
      )}
      {rejecting && (
        <div className="space-y-2">
          <input className="field" placeholder="Reason shown to the guest (e.g. Dosa sold out)" maxLength={120} value={reason} onChange={(e) => setReason(e.target.value)} />
          <div className="flex gap-2">
            <button
              className="btn border flex-1"
              style={{ borderColor: "var(--color-bad)", color: "var(--color-bad)" }}
              disabled={pending}
              onClick={() =>
                start(async () => {
                  const r = await rejectTableOrder(order.id, reason);
                  if (!r.ok) return setError(r.error);
                  router.refresh();
                })
              }
            >
              Reject order
            </button>
            <button className="btn" onClick={() => setRejecting(false)}>Back</button>
          </div>
        </div>
      )}
    </div>
  );
}
