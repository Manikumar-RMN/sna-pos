"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import type { FixOptions } from "@/lib/fo";
import { reissueInvoice, reopenStay } from "../../actions";

const bad = { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" };

/** Fixing a checked-out stay: reopen it (India, until night audit) or cancel and reissue the invoice (anywhere). */
export function FixPanel({ stayId, fix }: { stayId: string; fix: FixOptions }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [mode, setMode] = useState<null | "reopen" | "reissue">(null);
  const [err, setErr] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const b = fix.bill_to;
  const [f, setF] = useState({ name: b?.name ?? "", gstin: b?.gstin ?? "", address: b?.address ?? "", stateCode: b?.state_code ?? "" });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });

  if (!fix.has_right) return null;

  function run() {
    setErr(null);
    start(async () => {
      const r = mode === "reopen" ? await reopenStay(stayId, reason) : await reissueInvoice(stayId, fix.invoice_id ?? "", reason, f);
      if (r.ok) { setMode(null); setReason(""); router.refresh(); } else setErr(r.error);
    });
  }

  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Fix this stay after check-out</h2>
      {!mode && (
        <div className="mt-2 grid gap-3 sm:grid-cols-2">
          <div className="text-sm">
            <button className="btn h-10 min-h-0 px-4 text-sm" disabled={!fix.can_reopen} onClick={() => setMode("reopen")}>Reopen stay</button>
            <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>{fix.can_reopen ? "Puts the guest back in-house and cancels the invoice. Check out again to issue a new one." : fix.reopen_blocked}</p>
          </div>
          <div className="text-sm">
            <button className="btn h-10 min-h-0 px-4 text-sm" disabled={!fix.can_reissue} onClick={() => setMode("reissue")}>Cancel and reissue invoice</button>
            <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>{fix.can_reissue ? `Credit note for all of ${fix.invoice_no}, then a new invoice with corrected bill-to details. Amounts do not change.` : fix.reissue_blocked}</p>
          </div>
        </div>
      )}
      {mode && (
        <div className="mt-2">
          {err && <div role="alert" className="mb-2 rounded-xl px-3 py-2 text-sm font-semibold" style={bad}>{err}</div>}
          <label className="text-xs">Reason (required)<input className="field h-10 w-full text-sm" value={reason} onChange={(e) => setReason(e.target.value)} /></label>
          {mode === "reissue" && (
            <div className="mt-2 grid gap-2 sm:grid-cols-2">
              <label className="text-xs">Bill to (name)<input className="field h-10 w-full text-sm" value={f.name} onChange={set("name")} /></label>
              <label className="text-xs">GSTIN (if any)<input className="field h-10 w-full text-sm uppercase" maxLength={15} value={f.gstin} onChange={set("gstin")} /></label>
              <label className="text-xs sm:col-span-2">Address<input className="field h-10 w-full text-sm" value={f.address} onChange={set("address")} /></label>
              <label className="text-xs">State code<input className="field h-10 w-full text-sm" maxLength={2} inputMode="numeric" value={f.stateCode} onChange={set("stateCode")} /></label>
            </div>
          )}
          <div className="mt-3 flex gap-2">
            <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending || !reason.trim()} onClick={run}>{mode === "reopen" ? "Reopen stay" : "Cancel and reissue"}</button>
            <button className="btn h-10 min-h-0 px-4 text-sm" disabled={pending} onClick={() => { setMode(null); setErr(null); }}>Back</button>
          </div>
        </div>
      )}
    </section>
  );
}
