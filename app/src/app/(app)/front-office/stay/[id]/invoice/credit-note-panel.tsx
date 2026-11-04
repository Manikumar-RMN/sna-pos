"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState, useTransition } from "react";
import { money } from "@/lib/format";
import type { CreditOptions } from "@/lib/fo";
import { issueCreditNote } from "../../../actions";

/** Raise a credit note against this invoice: pick how much taxable value to take back per tax row. */
export function CreditNotePanel({ options, stayId, currency, canManage }: { options: CreditOptions; stayId: string; currency: string; canManage: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [vals, setVals] = useState<Record<string, string>>({});
  const ref = useRef(crypto.randomUUID());
  const key = (r: { sac: string; tax_pct: number }) => `${r.sac}|${r.tax_pct}`;
  const lines = options.rows
    .map((r) => ({ sac: r.sac, tax_pct: r.tax_pct, taxable: Number(vals[key(r)] ?? 0) }))
    .filter((l) => l.taxable > 0);
  const over = options.rows.some((r) => Number(vals[key(r)] ?? 0) > r.remaining_taxable);
  const anyLeft = options.rows.some((r) => r.remaining_taxable > 0);
  const bad = lines.some((l) => Math.round(l.taxable * 100) / 100 !== l.taxable);
  const valid = reason.trim() !== "" && lines.length > 0 && !over && !bad;

  function submit() {
    setMsg(null);
    start(async () => {
      const r = await issueCreditNote(options.invoice_id, stayId, reason.trim(), lines, ref.current);
      if (r.ok) { setMsg({ ok: true, text: r.message ?? "Issued." }); setOpen(false); setVals({}); setReason(""); ref.current = crypto.randomUUID(); router.push(`/front-office/stay/${stayId}/credit-note/${r.noteId}`); }
      else setMsg({ ok: false, text: r.error });
    });
  }

  return (
    <section className="no-print card mt-4 p-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-bold">Credit notes</h2>
        {canManage && options.party === "guest" && anyLeft && !open && <button className="btn h-9 min-h-0 px-3 text-sm" style={{ border: "1px solid var(--color-line)" }} onClick={() => { setMsg(null); setOpen(true); }}>Raise a credit note</button>}
      </div>
      {options.party === "company" && <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>Credit notes for company invoices are not supported yet.</p>}
      {options.notes.length === 0 ? <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>None raised against this invoice.</p> : (
        <ul className="mt-2 text-sm">
          {options.notes.map((n) => (
            <li key={n.id} className="flex flex-wrap justify-between gap-2 border-t py-1" style={{ borderColor: "var(--color-line)" }}>
              <Link href={`/front-office/stay/${stayId}/credit-note/${n.id}`} className="underline">{n.note_no}</Link>
              <span>{n.date} · {n.reason}</span><span>{money(n.total, currency)}</span>
            </li>
          ))}
        </ul>
      )}
      {msg && <div role="status" className="mt-2 rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg.text}</div>}
      {open && (
        <div className="mt-3 space-y-2">
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>Enter the taxable value to take back on each row. The tax is worked out at the row&apos;s rate. A credit note is a tax document only; refund the guest separately. Last day to raise one: {options.deadline}.</p>
          <table className="w-full text-sm">
            <thead><tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}><th>SAC</th><th className="text-right">Rate</th><th className="text-right">Invoiced</th><th className="text-right">Can still credit</th><th className="text-right">Credit</th></tr></thead>
            <tbody>{options.rows.map((r) => (
              <tr key={key(r)}>
                <td>{r.sac}</td><td className="text-right">{r.tax_pct}%</td><td className="text-right">{money(r.taxable, currency)}</td><td className="text-right">{money(r.remaining_taxable, currency)}</td>
                <td className="text-right"><input className="field h-9 w-28 text-right text-sm" inputMode="decimal" disabled={r.remaining_taxable <= 0} value={vals[key(r)] ?? ""} onChange={(e) => setVals({ ...vals, [key(r)]: e.target.value })} aria-label={`Credit for ${r.sac} at ${r.tax_pct} percent`} /></td>
              </tr>
            ))}</tbody>
          </table>
          {over && <p className="text-xs" style={{ color: "var(--color-bad-strong)" }}>One amount is more than can still be credited.</p>}
          <input className="field h-10 w-full text-sm" placeholder="Reason (printed on the note)" value={reason} onChange={(e) => setReason(e.target.value)} />
          <div className="flex gap-2">
            <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={!valid || pending} onClick={submit}>Issue credit note</button>
            <button className="btn h-10 min-h-0 px-4 text-sm" onClick={() => setOpen(false)}>Cancel</button>
          </div>
        </div>
      )}
    </section>
  );
}
