"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState, useTransition } from "react";
import { money } from "@/lib/format";
import { COMPANY_SCOPE_LABEL, STATUS_LABEL, type CompanyLedger } from "@/lib/fo";
import { takeCompanyPayment, voidCompanyPayment } from "../../actions";

/** One company's account: what each stay charged it, what it has paid, and what is overdue. */
export function CompanyAccount({ ledger, methods, currency, canManage }: { ledger: CompanyLedger; methods: { id: string; name: string }[]; currency: string; canManage: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [amt, setAmt] = useState("");
  const [ref, setRef] = useState("");
  const [method, setMethod] = useState("");
  const payRef = useRef(crypto.randomUUID());
  const { company: co, stays, payments, summary } = ledger;

  function act(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Done." } : { ok: false, text: r.error ?? "That did not work." });
      if (r.ok) { after?.(); router.refresh(); }
    });
  }

  return (
    <div className="mt-2 space-y-4">
      <header className="card p-4">
        <h1 className="text-xl font-extrabold">{co.name}{co.active ? "" : " (inactive)"}</h1>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          {co.gstin ? `GSTIN ${co.gstin} · ` : ""}{co.credit_days} credit days{co.credit_limit != null ? ` · limit ${money(co.credit_limit, currency)}` : ""}
          {co.contact_name ? ` · ${co.contact_name}` : ""}{co.phone ? ` · ${co.phone}` : ""}
        </p>
        <p className="mt-2 text-sm">
          Billed {money(summary.charged, currency)} · Paid {money(summary.paid, currency)} ·{" "}
          <b style={{ color: summary.outstanding > 0 ? "var(--color-bad)" : "var(--color-ok)" }}>{summary.outstanding > 0 ? `Owes ${money(summary.outstanding, currency)}` : summary.outstanding < 0 ? `Paid ahead ${money(-summary.outstanding, currency)}` : "Nothing owed"}</b>
        </p>
        {summary.overdue > 0 && <p className="mt-1 text-sm font-semibold" style={{ color: "var(--color-bad)" }}>Overdue {money(summary.overdue, currency)}. Payments are counted against the oldest stays first.</p>}
        {summary.over_limit && <p className="mt-1 text-sm font-semibold" style={{ color: "var(--color-bad)" }}>Over the credit limit.</p>}
      </header>

      {msg && <div role="status" className="rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg.text}</div>}

      <section className="card p-4">
        <h2 className="text-sm font-bold">Stays billed to this company</h2>
        <ul className="mt-2 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
          {stays.length === 0 && <li className="py-2" style={{ color: "var(--color-ink-3)" }}>Nothing yet. A stay appears here once the guest checks in.</li>}
          {stays.map((s) => (
            <li key={s.stay_id} className="flex flex-wrap items-center justify-between gap-2 py-2">
              <span>
                <Link href={`/front-office/stay/${s.stay_id}`} className="font-semibold underline">#{s.stay_no} · {s.guest_name}</Link>
                <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {s.room_number ? `Room ${s.room_number} · ` : ""}{s.arrival} to {s.departure} · {STATUS_LABEL[s.status] ?? s.status} · pays {COMPANY_SCOPE_LABEL[s.scope]?.toLowerCase() ?? s.scope}
                  {s.invoice_no ? ` · invoice ${s.invoice_no}` : s.status === "checked_out" ? " · invoice not issued yet" : ""} · due {s.due_date}
                </span>
              </span>
              <b>{money(s.charged, currency)}</b>
            </li>
          ))}
        </ul>
      </section>

      <section className="card p-4">
        <h2 className="text-sm font-bold">Payments received</h2>
        <ul className="mt-2 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
          {payments.length === 0 && <li className="py-2" style={{ color: "var(--color-ink-3)" }}>No payments yet.</li>}
          {payments.map((p) => (
            <li key={p.payment_id} className="flex items-center justify-between gap-2 py-2" style={p.voided ? { opacity: 0.5, textDecoration: "line-through" } : undefined}>
              <span>{p.on} · {p.method}{p.reference ? ` · ${p.reference}` : ""}{p.void_reason ? ` · voided: ${p.void_reason}` : ""}</span>
              <span className="flex items-center gap-2">
                <b>{money(p.amount, currency)}</b>
                {canManage && !p.voided && (
                  <button className="text-xs underline" disabled={pending} onClick={() => { const r = window.prompt("Why are you voiding this payment?"); if (r && r.trim()) act(() => voidCompanyPayment(co.company_id, p.payment_id, r.trim())); }}>Void</button>
                )}
              </span>
            </li>
          ))}
        </ul>
        {canManage && (
          <div className="mt-3 grid gap-2 sm:grid-cols-[1fr_1fr_2fr_auto]">
            <select className="field h-10 text-sm" value={method} onChange={(e) => setMethod(e.target.value)} aria-label="Payment method">
              <option value="">Bank transfer</option>
              {methods.map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
            </select>
            <input className="field h-10 text-sm" inputMode="decimal" placeholder={summary.outstanding > 0 ? String(summary.outstanding) : "Amount"} value={amt} onChange={(e) => setAmt(e.target.value)} aria-label="Amount" />
            <input className="field h-10 text-sm" placeholder="Reference (cheque or transfer no.)" value={ref} onChange={(e) => setRef(e.target.value)} aria-label="Reference" />
            <button className="btn btn-pay h-10 min-h-0 px-4 text-sm" disabled={pending || !(Number(amt) > 0)}
              onClick={() => act(() => takeCompanyPayment(co.company_id, Number(amt), method || null, ref.trim(), payRef.current), () => { payRef.current = crypto.randomUUID(); setAmt(""); setRef(""); })}>Record payment</button>
          </div>
        )}
      </section>
    </div>
  );
}
