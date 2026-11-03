"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import type { Company } from "@/lib/fo";
import { saveCompany } from "../actions";

const blank = { id: null as string | null, name: "", gstin: "", stateCode: "", address: "", contactName: "", phone: "", email: "", creditDays: "30", creditLimit: "", active: true };

/** Companies that can be billed for a guest's stay, with what each one owes. */
export function CompaniesClient({ companies, currency, canManage }: { companies: Company[]; currency: string; canManage: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [form, setForm] = useState<typeof blank | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const set = (k: Exclude<keyof typeof blank, "id" | "active">) => (e: { target: { value: string } }) => form && setForm({ ...form, [k]: e.target.value });

  function edit(c: Company) {
    setMsg(null);
    setForm({ id: c.company_id, name: c.name, gstin: c.gstin ?? "", stateCode: c.state_code ?? "", address: c.address ?? "", contactName: c.contact_name ?? "", phone: c.phone ?? "", email: c.email ?? "", creditDays: String(c.credit_days), creditLimit: c.credit_limit == null ? "" : String(c.credit_limit), active: c.active });
  }
  function save() {
    if (!form) return;
    setMsg(null);
    start(async () => {
      const r = await saveCompany({
        id: form.id, name: form.name.trim(), gstin: form.gstin.trim().toUpperCase(), stateCode: form.stateCode.trim(), address: form.address.trim(),
        contactName: form.contactName.trim(), phone: form.phone.trim(), email: form.email.trim(), creditDays: Number(form.creditDays),
        creditLimit: form.creditLimit.trim() === "" ? null : Number(form.creditLimit), active: form.active,
      });
      if (r.ok) { setMsg({ ok: true, text: r.message ?? "Saved." }); setForm(null); router.refresh(); }
      else setMsg({ ok: false, text: r.error });
    });
  }
  const valid = !!form && form.name.trim() !== "" && Number.isInteger(Number(form.creditDays)) && Number(form.creditDays) >= 0 && Number(form.creditDays) <= 365 && (form.creditLimit.trim() === "" || Number(form.creditLimit) >= 0);

  return (
    <div className="mt-2 space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-xl font-extrabold">Companies</h1>
        {canManage && <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" onClick={() => { setMsg(null); setForm({ ...blank }); }}>Add company</button>}
      </div>
      <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>A company can pay for a guest&apos;s room, or for everything on the folio. The company gets its own tax invoice and pays later, on credit.</p>

      {msg && <div role="status" className="rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg.text}</div>}

      {form && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">{form.id ? "Edit company" : "New company"}</h2>
          <div className="mt-2 grid gap-2 sm:grid-cols-2">
            <label className="text-xs">Company name<input className="field h-10 w-full text-sm" value={form.name} onChange={set("name")} /></label>
            <label className="text-xs">GSTIN<input className="field h-10 w-full text-sm uppercase" maxLength={15} value={form.gstin} onChange={set("gstin")} /></label>
            <label className="text-xs sm:col-span-2">Address<input className="field h-10 w-full text-sm" value={form.address} onChange={set("address")} /></label>
            <label className="text-xs">State code (2 digits)<input className="field h-10 w-full text-sm" maxLength={2} inputMode="numeric" value={form.stateCode} onChange={set("stateCode")} /></label>
            <label className="text-xs">Contact person<input className="field h-10 w-full text-sm" value={form.contactName} onChange={set("contactName")} /></label>
            <label className="text-xs">Phone<input className="field h-10 w-full text-sm" inputMode="tel" value={form.phone} onChange={set("phone")} /></label>
            <label className="text-xs">Email<input className="field h-10 w-full text-sm" inputMode="email" value={form.email} onChange={set("email")} /></label>
            <label className="text-xs">Credit days (0 to 365)<input className="field h-10 w-full text-sm" inputMode="numeric" value={form.creditDays} onChange={set("creditDays")} /></label>
            <label className="text-xs">Credit limit (optional)<input className="field h-10 w-full text-sm" inputMode="decimal" value={form.creditLimit} onChange={set("creditLimit")} /></label>
            <label className="flex items-center gap-2 text-sm sm:col-span-2"><input type="checkbox" checked={form.active} onChange={(e) => setForm({ ...form, active: e.target.checked })} /> Active (can be chosen on new stays)</label>
          </div>
          <div className="mt-3 flex gap-2">
            <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending || !valid} onClick={save}>Save company</button>
            <button className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }} onClick={() => setForm(null)}>Close</button>
          </div>
        </section>
      )}

      <section className="card p-4">
        <ul className="divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
          {companies.length === 0 && <li className="py-2" style={{ color: "var(--color-ink-3)" }}>No companies yet.</li>}
          {companies.map((c) => (
            <li key={c.company_id} className="flex flex-wrap items-center justify-between gap-2 py-2" style={c.active ? undefined : { opacity: 0.55 }}>
              <span>
                <Link href={`/front-office/companies/${c.company_id}`} className="font-semibold underline">{c.name}</Link>{c.active ? "" : " (inactive)"}
                <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {c.gstin ? `GSTIN ${c.gstin} · ` : "No GSTIN · "}{c.credit_days} credit days{c.credit_limit != null ? ` · limit ${money(c.credit_limit, currency)}` : ""}
                </span>
              </span>
              <span className="flex items-center gap-3">
                <b style={{ color: c.outstanding > 0 ? "var(--color-bad)" : undefined }}>{c.outstanding > 0 ? `Owes ${money(c.outstanding, currency)}` : c.outstanding < 0 ? `Paid ahead ${money(-c.outstanding, currency)}` : "Nothing owed"}</b>
                {canManage && <button className="text-xs underline" onClick={() => edit(c)}>Edit</button>}
              </span>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
