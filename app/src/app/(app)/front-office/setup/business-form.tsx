"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import type { BusinessDetails } from "@/lib/fo";
import { saveBusiness } from "../actions";

/** The hotel's legal details, printed on every GST tax invoice. */
export function BusinessForm({ initial, currency }: { initial: BusinessDetails; currency: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [f, setF] = useState({
    legalName: initial.legal_name ?? "", gstin: initial.gstin ?? "", stateCode: initial.state_code ?? "",
    address: initial.address ?? "", phone: initial.phone ?? "", email: initial.email ?? "",
    invoicePrefix: initial.invoice_prefix ?? "FO", invoiceFooter: initial.invoice_footer ?? "",
    noGstBelow: String(initial.room_tax_exempt_below ?? 1000),
  });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value });

  function save() {
    setMsg(null);
    start(async () => {
      const r = await saveBusiness({ ...f, gstin: f.gstin.trim().toUpperCase(), invoicePrefix: f.invoicePrefix.trim().toUpperCase(), noGstBelow: Number(f.noGstBelow) || 0 });
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
      if (r.ok) router.refresh();
    });
  }
  const missing = !f.legalName.trim() || !f.address.trim();

  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Business details for the tax invoice</h2>
      <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Printed on every GST invoice. The legal name and address are needed before the first invoice. The GSTIN is needed when the bill carries GST. Invoice numbers run from 1 each 1 April, like SR/2627/000001.
      </p>
      {msg && (
        <div role="status" className="mt-2 rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg.text}</div>
      )}
      <div className="mt-2 grid gap-2 sm:grid-cols-2">
        <label className="text-xs sm:col-span-2">Legal name of the hotel<input className="field h-10 w-full text-sm" value={f.legalName} onChange={set("legalName")} /></label>
        <label className="text-xs sm:col-span-2">Address on the invoice<textarea className="field w-full text-sm" rows={2} value={f.address} onChange={set("address")} /></label>
        <label className="text-xs">GSTIN<input className="field h-10 w-full text-sm uppercase" maxLength={15} placeholder="33AAACA0000A1Z5" value={f.gstin} onChange={set("gstin")} /></label>
        <label className="text-xs">State code (two digits, filled from the GSTIN)<input className="field h-10 w-full text-sm" maxLength={2} inputMode="numeric" value={f.stateCode} onChange={set("stateCode")} /></label>
        <label className="text-xs">Phone<input className="field h-10 w-full text-sm" value={f.phone} onChange={set("phone")} /></label>
        <label className="text-xs">Email<input className="field h-10 w-full text-sm" value={f.email} onChange={set("email")} /></label>
        <label className="text-xs">Invoice prefix (1 to 4 letters)<input className="field h-10 w-full text-sm uppercase" maxLength={4} value={f.invoicePrefix} onChange={set("invoicePrefix")} /></label>
        <label className="text-xs">No GST on a room priced below ({currency}/night)<input className="field h-10 w-full text-sm" inputMode="decimal" value={f.noGstBelow} onChange={set("noGstBelow")} /></label>
        <label className="text-xs sm:col-span-2">Line at the bottom of the invoice<input className="field h-10 w-full text-sm" value={f.invoiceFooter} onChange={set("invoiceFooter")} /></label>
      </div>
      <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
        The no-GST limit and the tax rates above are set from what we found in the public GST notes. Confirm them with your accountant before you rely on them.
      </p>
      <button className="btn btn-primary mt-3 h-10 min-h-0 px-4 text-sm" disabled={pending || missing} onClick={save}>Save business details</button>
    </section>
  );
}
