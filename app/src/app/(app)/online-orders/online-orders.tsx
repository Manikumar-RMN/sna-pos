"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { acceptOnline, rejectOnline } from "./actions";

export type OnlineOrder = {
  id: string;
  channel: string;
  external_ref: string;
  status: "pending" | "accepted" | "rejected";
  customer_name: string | null;
  customer_phone: string | null;
  address: string | null;
  note: string | null;
  paid_online: boolean;
  partner_total: number | null;
  created_at: string;
  reject_reason: string | null;
  bill_number: string | null;
  order_id: string | null;
  items: { name: string; qty: number; note: string | null }[];
};

export function OnlineOrders({ currency, canAccept, orders }: { currency: string; canAccept: boolean; orders: OnlineOrder[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [rejecting, setRejecting] = useState<{ id: string; reason: string } | null>(null);
  const waiting = orders.filter((o) => o.status === "pending");
  const done = orders.filter((o) => o.status !== "pending");
  const seen = useRef(new Set(waiting.map((o) => o.id)));

  // New orders arrive by themselves: refresh every 10 seconds and beep when a new one comes in.
  useEffect(() => {
    const t = setInterval(() => router.refresh(), 10000);
    return () => clearInterval(t);
  }, [router]);
  useEffect(() => {
    const fresh = waiting.some((o) => !seen.current.has(o.id));
    waiting.forEach((o) => seen.current.add(o.id));
    if (fresh) {
      try {
        const ctx = new AudioContext();
        const osc = ctx.createOscillator();
        osc.frequency.value = 880;
        osc.connect(ctx.destination);
        osc.start();
        osc.stop(ctx.currentTime + 0.25);
      } catch {
        /* sound is optional */
      }
    }
  }, [waiting]);

  const m = (n: number) => money(n, currency);
  const label = (c: string) => c.charAt(0).toUpperCase() + c.slice(1).replace(/_/g, " ");

  return (
    <div className="mx-auto max-w-5xl space-y-4">
      <div>
        <h1 className="text-xl font-bold tracking-tight">Online orders</h1>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          Orders from Swiggy, Zomato or your website arrive here through your online-ordering partner. Accept to make the delivery bill and send it
          to the kitchen; then send it out from Deliveries, or hand it to the partner&rsquo;s rider.
        </p>
      </div>
      {error && <p className="text-sm" role="alert" style={{ color: "var(--color-bad)" }}>{error}</p>}

      <section className="space-y-3">
        <h2 className="text-sm font-bold">Waiting ({waiting.length})</h2>
        {waiting.length === 0 && <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No orders waiting.</p>}
        {waiting.map((o) => (
          <div key={o.id} className="card p-4">
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <span className="rounded-md px-2 py-0.5 text-xs font-bold text-white" style={{ background: "var(--color-brand)" }}>{label(o.channel)}</span>
                <span className="ml-2 font-bold">#{o.external_ref}</span>
                <span className="ml-2 text-xs" style={{ color: "var(--color-ink-3)" }}>{new Date(o.created_at).toLocaleTimeString("en-IN", { timeStyle: "short" })}</span>
                <div className="mt-1 text-sm">{[o.customer_name, o.customer_phone].filter(Boolean).join(" · ")}</div>
                {o.address && <div className="text-xs" style={{ color: "var(--color-ink-2)" }}>{o.address}</div>}
              </div>
              <div className="text-right text-sm">
                {o.partner_total != null && <div className="font-semibold tabular-nums">{m(Number(o.partner_total))}</div>}
                <div className="text-xs font-semibold" style={{ color: o.paid_online ? "var(--color-ok)" : "var(--color-warn)" }}>{o.paid_online ? "Paid online" : "Cash on delivery"}</div>
              </div>
            </div>
            <ul className="mt-2 text-sm">
              {o.items.map((it, i) => (
                <li key={i}>
                  {it.qty} × {it.name}
                  {it.note && <span className="text-xs" style={{ color: "var(--color-ink-3)" }}> — {it.note}</span>}
                </li>
              ))}
            </ul>
            {o.note && <p className="mt-1 text-xs">Customer note: {o.note}</p>}
            {canAccept && (
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <button
                  className="btn btn-pay"
                  disabled={pending}
                  onClick={() =>
                    start(async () => {
                      const r = await acceptOnline(o.id);
                      setError(r.ok ? null : r.error);
                    })
                  }
                >
                  Accept
                </button>
                {rejecting?.id === o.id ? (
                  <>
                    <input className="field w-56" placeholder="Reason, e.g. Item not available" value={rejecting.reason} onChange={(e) => setRejecting({ id: o.id, reason: e.target.value })} />
                    <button
                      className="btn"
                      disabled={pending}
                      onClick={() =>
                        start(async () => {
                          const r = await rejectOnline(o.id, rejecting.reason);
                          setError(r.ok ? null : r.error);
                          if (r.ok) setRejecting(null);
                        })
                      }
                    >
                      Reject
                    </button>
                  </>
                ) : (
                  <button className="btn border" style={{ borderColor: "var(--color-line)" }} onClick={() => setRejecting({ id: o.id, reason: "" })}>
                    Reject…
                  </button>
                )}
              </div>
            )}
          </div>
        ))}
      </section>

      {done.length > 0 && (
        <section>
          <h2 className="mb-2 text-sm font-bold">Last 24 hours</h2>
          <div className="card divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
            {done.map((o) => (
              <div key={o.id} className="flex flex-wrap items-center justify-between gap-2 px-4 py-2">
                <span>
                  {label(o.channel)} #{o.external_ref} · {o.customer_name ?? ""}
                </span>
                <span>
                  {o.status === "accepted" && o.order_id ? (
                    <Link className="font-semibold underline" href={`/bills/${o.order_id}`}>{o.bill_number}</Link>
                  ) : (
                    <span style={{ color: "var(--color-bad)" }}>Rejected{o.reject_reason ? `: ${o.reject_reason}` : ""}</span>
                  )}
                </span>
              </div>
            ))}
          </div>
        </section>
      )}

      <details className="card p-4 text-sm">
        <summary className="cursor-pointer font-semibold">For your online-ordering partner (technical)</summary>
        <p className="mt-2" style={{ color: "var(--color-ink-2)" }}>
          Create an API key in Settings → API keys and give it to the partner. They send each new order to:
        </p>
        <pre className="mt-2 overflow-x-auto rounded-lg p-3 text-xs" style={{ background: "var(--color-ground)" }}>{`POST /api/v1/online-orders
Authorization: Bearer snapi_…
{
  "channel": "swiggy",            // or zomato, website …
  "order_id": "SW-123456",        // their order number (sent twice = taken once)
  "outlet_code": "MN",            // optional, when you have several outlets
  "customer": { "name": "…", "phone": "…", "address": "…" },
  "paid_online": true,
  "total": 450.00,
  "note": "Ring the bell",
  "items": [ { "product_id": "…" | "item_code": "…", "qty": 2, "options": ["…"], "note": "less spicy" } ]
}`}</pre>
        <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Dish ids come from GET /api/v1/menu, or use the item code set on each dish. The bill uses your menu prices.
        </p>
      </details>
    </div>
  );
}
