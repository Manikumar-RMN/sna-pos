"use client";

import { useEffect, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { saveRider, settleRider, updateDelivery } from "./actions";

export type Delivery = {
  id: string;
  bill_number: string;
  token_no: number | null;
  status: "waiting" | "out" | "delivered" | "returned";
  rider_id: string | null;
  rider: string | null;
  guest_name: string | null;
  guest_phone: string | null;
  address: string | null;
  total: number;
  due: number;
  created_at: string;
  out_at: string | null;
  delivered_at: string | null;
};
type Rider = { id: string; name: string; phone: string | null; is_active: boolean };

const minutes = (iso: string | null) => (iso ? Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000)) : 0);

export function Deliveries({ currency, canSettle, deliveries, riders }: { currency: string; canSettle: boolean; deliveries: Delivery[]; riders: Rider[] }) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [pick, setPick] = useState<Record<string, string>>({});
  const [newRider, setNewRider] = useState({ name: "", phone: "" });
  const m = (n: number) => money(n, currency);
  const active = riders.filter((r) => r.is_active);

  // The list refreshes itself every 20 seconds.
  useEffect(() => {
    const t = setInterval(() => router.refresh(), 20000);
    return () => clearInterval(t);
  }, [router]);

  const act = (fn: () => Promise<{ ok: boolean; error?: string }>, done?: string) =>
    start(async () => {
      const r = await fn();
      setError(r.ok ? null : (r as { error: string }).error);
      setNote(r.ok && done ? done : null);
    });

  const col = (status: Delivery["status"][]) => deliveries.filter((d) => status.includes(d.status));
  // Cash each rider is holding: delivered, not yet paid.
  const holding = active
    .map((r) => ({ r, bills: deliveries.filter((d) => d.rider_id === r.id && d.status === "delivered" && Number(d.due) > 0) }))
    .filter((x) => x.bills.length > 0);

  const card = (d: Delivery) => (
    <div key={d.id} className="rounded-xl border p-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <Link href={`/bills/${d.id}`} className="font-bold underline">
            {d.bill_number}
          </Link>
          {d.token_no != null && <span className="ml-1.5 text-xs" style={{ color: "var(--color-ink-3)" }}>Token {d.token_no}</span>}
          <div className="truncate">{[d.guest_name, d.guest_phone].filter(Boolean).join(" · ") || "No name"}</div>
          {d.address && <div className="text-xs" style={{ color: "var(--color-ink-2)" }}>{d.address}</div>}
        </div>
        <div className="text-right tabular-nums">
          <div className="font-semibold">{m(Number(d.total))}</div>
          <div className="text-xs" style={{ color: Number(d.due) > 0 ? "var(--color-warn)" : "var(--color-ok)" }}>
            {Number(d.due) > 0 ? `Collect ${m(Number(d.due))}` : "Paid"}
          </div>
        </div>
      </div>
      <div className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        {d.status === "waiting" && `Waiting ${minutes(d.created_at)} min`}
        {d.status === "out" && `${d.rider} · out ${minutes(d.out_at)} min`}
        {d.status === "delivered" && `${d.rider ?? ""} · delivered ${new Date(d.delivered_at ?? d.created_at).toLocaleTimeString("en-IN", { timeStyle: "short" })}`}
        {d.status === "returned" && `Returned${d.rider ? ` by ${d.rider}` : ""}`}
      </div>
      <div className="mt-2 flex flex-wrap gap-2">
        {d.status === "waiting" && (
          <>
            <select
              className="field w-40"
              value={pick[d.id] ?? active[0]?.id ?? ""}
              onChange={(e) => setPick({ ...pick, [d.id]: e.target.value })}
              aria-label="Rider"
            >
              {active.length === 0 && <option value="">Add a rider first</option>}
              {active.map((r) => (
                <option key={r.id} value={r.id}>{r.name}</option>
              ))}
            </select>
            <button className="btn btn-primary" style={{ minHeight: 40 }} disabled={pending || active.length === 0} onClick={() => act(() => updateDelivery(d.id, "out", pick[d.id] ?? active[0]?.id))}>
              Send out
            </button>
          </>
        )}
        {d.status === "out" && (
          <>
            <button className="btn btn-pay" style={{ minHeight: 40 }} disabled={pending} onClick={() => act(() => updateDelivery(d.id, "delivered"))}>
              Delivered
            </button>
            <button className="btn" style={{ minHeight: 40 }} disabled={pending} onClick={() => act(() => updateDelivery(d.id, "returned"))}>
              Came back
            </button>
          </>
        )}
        {(d.status === "returned" || d.status === "out") && (
          <button className="btn" style={{ minHeight: 40 }} disabled={pending} onClick={() => act(() => updateDelivery(d.id, "waiting"))}>
            Back to waiting
          </button>
        )}
      </div>
    </div>
  );

  return (
    <div className="mx-auto max-w-6xl space-y-4">
      <div>
        <h1 className="text-xl font-bold tracking-tight">Deliveries</h1>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          Delivery bills from the billing screen appear here. Send each one out with a rider and mark it delivered. Cash on delivery stays
          unpaid until the rider hands it over — then press &ldquo;Settle&rdquo; for that rider.
        </p>
      </div>
      {error && <p className="text-sm" role="alert" style={{ color: "var(--color-bad)" }}>{error}</p>}
      {note && <p className="text-sm" role="status" style={{ color: "var(--color-ok)" }}>{note}</p>}

      {canSettle && holding.length > 0 && (
        <section className="card p-4">
          <h2 className="mb-2 text-sm font-bold">Cash with riders</h2>
          <div className="space-y-2">
            {holding.map(({ r, bills }) => {
              const amt = bills.reduce((s, b) => s + Number(b.due), 0);
              return (
                <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 text-sm">
                  <span>
                    <b>{r.name}</b> · {bills.length} {bills.length === 1 ? "bill" : "bills"} · {m(amt)}
                  </span>
                  <button className="btn btn-pay" style={{ minHeight: 40 }} disabled={pending} onClick={() => act(() => settleRider(r.id), `${r.name}: ${m(amt)} taken into the drawer.`)}>
                    Settle {m(amt)} in cash
                  </button>
                </div>
              );
            })}
          </div>
        </section>
      )}

      <div className="grid gap-4 md:grid-cols-3">
        {(
          [
            ["Waiting for a rider", ["waiting"]],
            ["Out for delivery", ["out"]],
            ["Delivered / returned (last 24 hours)", ["delivered", "returned"]],
          ] as [string, Delivery["status"][]][]
        ).map(([title, st]) => (
          <section key={title} className="space-y-2">
            <h2 className="text-sm font-bold">
              {title} <span style={{ color: "var(--color-ink-3)" }}>({col(st).length})</span>
            </h2>
            {col(st).length === 0 ? <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>None.</p> : col(st).map(card)}
          </section>
        ))}
      </div>

      <section className="card p-4">
        <h2 className="mb-2 text-sm font-bold">Riders</h2>
        <div className="mb-3 flex flex-wrap gap-2 text-sm">
          {riders.length === 0 && <span style={{ color: "var(--color-ink-3)" }}>No riders yet.</span>}
          {riders.map((r) => (
            <span key={r.id} className="inline-flex items-center gap-2 rounded-lg border px-2.5 py-1.5" style={{ borderColor: "var(--color-line)" }}>
              {r.name}
              {r.phone && <span style={{ color: "var(--color-ink-3)" }}>{r.phone}</span>}
              <button className="text-xs underline" disabled={pending} onClick={() => act(() => saveRider(r.id, r.name, r.phone ?? "", !r.is_active))}>
                {r.is_active ? "Stop using" : "Use again"}
              </button>
            </span>
          ))}
        </div>
        <div className="flex flex-wrap gap-2">
          <input className="field w-44" placeholder="Rider name" maxLength={60} value={newRider.name} onChange={(e) => setNewRider({ ...newRider, name: e.target.value })} />
          <input className="field w-40" type="tel" placeholder="Phone (optional)" value={newRider.phone} onChange={(e) => setNewRider({ ...newRider, phone: e.target.value })} />
          <button
            className="btn btn-primary"
            disabled={pending || !newRider.name.trim()}
            onClick={() =>
              act(async () => {
                const r = await saveRider(null, newRider.name, newRider.phone);
                if (r.ok) setNewRider({ name: "", phone: "" });
                return r;
              })
            }
          >
            Add rider
          </button>
        </div>
      </section>
    </div>
  );
}
