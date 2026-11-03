"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import type { InvoiceState } from "@/lib/fo";
import { issueInvoice } from "../../actions";

/** GST tax invoice for a checked-out stay: issue it once, then view or print it. An issued invoice never changes. */
export function InvoicePanel({ stayId, state, canManage }: { stayId: string; state: InvoiceState; canManage: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const pre = state.issued ? null : state.prefill;
  const [f, setF] = useState({ name: pre?.name ?? "", gstin: pre?.gstin ?? "", address: pre?.address ?? "", stateCode: pre?.state_code ?? "" });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });

  if (state.issued) {
    return (
      <section className="card flex flex-wrap items-center justify-between gap-3 p-4">
        <div>
          <h2 className="text-sm font-bold">Tax invoice</h2>
          <p className="text-sm">Invoice <b>{state.invoice_no}</b> · dated {state.invoice_date}</p>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>An issued invoice cannot be changed. A mistake is corrected with a credit note.</p>
        </div>
        <Link href={`/front-office/stay/${stayId}/invoice`} className="btn btn-primary h-10 min-h-0 px-4 text-sm">View and print invoice</Link>
      </section>
    );
  }
  if (!canManage) return null;
  if (!state.has_business_details) {
    return (
      <section className="card p-4 text-sm">
        <h2 className="text-sm font-bold">Tax invoice</h2>
        <p className="mt-1">Add the hotel&apos;s legal name and address first. <Link href="/front-office/setup" className="underline">Open rooms and rates</Link>, then fill in &ldquo;Business details for the tax invoice&rdquo;.</p>
      </section>
    );
  }

  function issue() {
    setErr(null);
    start(async () => {
      const r = await issueInvoice(stayId, { name: f.name.trim(), gstin: f.gstin.trim().toUpperCase(), address: f.address.trim(), stateCode: f.stateCode.trim() });
      if (r.ok) router.refresh();
      else setErr(r.error);
    });
  }
  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Tax invoice</h2>
      <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Leave the company fields empty to bill the guest. For a company, fill the name and GSTIN so the company can claim the tax. Once issued, the invoice cannot be changed.
      </p>
      {err && <div role="alert" className="mt-2 rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{err}</div>}
      <div className="mt-2 grid gap-2 sm:grid-cols-2">
        <label className="text-xs">Bill to (name)<input className="field h-10 w-full text-sm" value={f.name} onChange={set("name")} /></label>
        <label className="text-xs">Company GSTIN (if any)<input className="field h-10 w-full text-sm uppercase" maxLength={15} value={f.gstin} onChange={set("gstin")} /></label>
        <label className="text-xs sm:col-span-2">Address<input className="field h-10 w-full text-sm" value={f.address} onChange={set("address")} /></label>
        <label className="text-xs">State code<input className="field h-10 w-full text-sm" maxLength={2} inputMode="numeric" value={f.stateCode} onChange={set("stateCode")} /></label>
      </div>
      <button className="btn btn-primary mt-3 h-10 min-h-0 px-4 text-sm" disabled={pending} onClick={issue}>Issue tax invoice</button>
    </section>
  );
}
