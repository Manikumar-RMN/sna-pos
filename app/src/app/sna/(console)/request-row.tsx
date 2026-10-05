"use client";

import Link from "next/link";
import { useState, useTransition } from "react";
import { decideRequest } from "./actions";

export type SnaRequest = {
  id: string;
  restaurant_id: string;
  trading_name?: string;
  kind: "upgrade" | "module" | "outlet";
  module_key: string | null;
  outlet_name: string | null;
  outlet_city: string | null;
  note: string | null;
  status: string;
  created_at: string;
  decision_note: string | null;
};

export function requestLabel(r: SnaRequest) {
  if (r.kind === "upgrade") return "Upgrade to Professional";
  if (r.kind === "module") return `Add-on: ${r.module_key}`;
  return `New outlet: ${r.outlet_name}${r.outlet_city ? `, ${r.outlet_city}` : ""}`;
}

/** One request with the buttons this SNA role may use. */
export function RequestRow({ request: r, role }: { request: SnaRequest; role: string }) {
  const [pending, start] = useTransition();
  const [note, setNote] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const canDecide = role === "admin" || role === "sales";
  const canBuild = role === "admin" || role === "implementer";

  const decide = (approve: boolean) =>
    start(async () => {
      const res = await decideRequest(r.id, approve, note);
      setMsg(res.ok ? res.message : res.error);
    });

  return (
    <div className="flex flex-wrap items-center gap-3 p-4 text-sm">
      <div className="min-w-0 flex-1">
        <div className="font-semibold">
          {r.trading_name ? (
            <Link href={`/sna/r/${r.restaurant_id}`} style={{ color: "var(--color-brand)" }}>
              {r.trading_name}
            </Link>
          ) : null}
          {r.trading_name ? " · " : ""}
          {requestLabel(r)}
        </div>
        <div style={{ color: "var(--color-ink-3)" }}>
          {new Date(r.created_at).toLocaleString()} · {r.status === "approved" ? "Approved — waiting for implementer" : "Waiting for sales"}
          {r.note ? ` · “${r.note}”` : ""}
        </div>
        {msg && <div className="mt-1 font-semibold">{msg}</div>}
      </div>
      {r.status === "requested" && canDecide && (
        <div className="flex flex-wrap items-center gap-2">
          <input className="field h-10 w-48" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          <button className="btn btn-pay h-10 min-h-0 px-4 text-sm" disabled={pending} onClick={() => decide(true)}>
            Approve
          </button>
          <button className="btn h-10 min-h-0 px-4 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }} disabled={pending} onClick={() => decide(false)}>
            Reject
          </button>
        </div>
      )}
      {r.status === "approved" && r.kind === "outlet" && canBuild && (
        <Link href={`/sna/r/${r.restaurant_id}#outlet-${r.id}`} className="btn btn-pay h-10 min-h-0 px-4 text-sm">
          Set up outlet
        </Link>
      )}
    </div>
  );
}
