import Link from "next/link";
import { redirect } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import type { CreditNote } from "@/lib/fo";
import { PrintButton } from "../../../../../print-button";

/** An issued GST credit note, laid out for A4. */
export default async function CreditNotePage({ params }: { params: Promise<{ id: string; noteId: string }> }) {
  const { id, noteId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id) || !/^[0-9a-f-]{36}$/i.test(noteId)) redirect("/front-office");
  const user = await requireUser();
  if (!has(user, "front_office") || !(can(user, "fo.view") || can(user, "fo.manage"))) redirect("/front-office");
  const { data } = await (await createClient()).rpc("fo_credit_note_get", { p_note: noteId });
  const n = data as unknown as CreditNote | null;
  if (!n || n.stay_id !== id) redirect(`/front-office/stay/${id}`);
  const s = n.snapshot;
  const c = user.currency_code;

  return (
    <div className="mx-auto max-w-3xl">
      <div className="no-print mb-3 flex items-center justify-between gap-3">
        <Link href={`/front-office/stay/${id}/invoice`} className="text-sm underline">← Invoice</Link>
        <div className="w-40"><PrintButton label="Print credit note" /></div>
      </div>
      <div className="report-root card p-6 text-[13px] leading-snug" style={{ background: "#fff", color: "#111" }}>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div className="text-lg font-extrabold">{s.property.legal_name}</div>
            <div className="whitespace-pre-line">{s.property.address}</div>
            {s.property.gstin && <div className="font-semibold">GSTIN {s.property.gstin}</div>}
          </div>
          <div className="text-right">
            <div className="text-lg font-extrabold tracking-wide">CREDIT NOTE</div>
            <div>No. <b>{n.note_no}</b></div>
            <div>Date {n.date}</div>
            <div>Against invoice <b>{s.against.invoice_no}</b> dated {s.against.invoice_date}</div>
          </div>
        </div>
        <div className="mt-4">
          <div className="text-xs font-bold uppercase" style={{ color: "#555" }}>Issued to</div>
          <div className="font-semibold">{s.bill_to.name}</div>
          {s.bill_to.address && <div className="whitespace-pre-line">{s.bill_to.address}</div>}
          {s.bill_to.gstin && <div>GSTIN {s.bill_to.gstin}</div>}
          <div className="mt-1">Stay #{s.stay.stay_no} · {s.stay.arrival} to {s.stay.departure}</div>
        </div>
        <div className="mt-3"><span className="text-xs font-bold uppercase" style={{ color: "#555" }}>Reason</span><div>{s.reason}</div></div>
        <table className="mt-4 w-full border-collapse text-[12px]">
          <thead>
            <tr style={{ borderBottom: "1px solid #111", borderTop: "1px solid #111" }}>
              <th className="py-1 text-left">SAC</th><th className="text-right">Rate</th><th className="text-right">Taxable value</th><th className="text-right">CGST</th><th className="text-right">SGST</th><th className="text-right">Amount</th>
            </tr>
          </thead>
          <tbody>{s.lines.map((l, i) => (
            <tr key={i} style={{ borderBottom: "1px solid #ddd" }}>
              <td className="py-1">{l.sac}</td><td className="text-right">{l.tax_pct}%</td><td className="text-right">{money(l.taxable, c)}</td>
              <td className="text-right">{money(l.cgst, c)}</td><td className="text-right">{money(l.sgst, c)}</td><td className="text-right">{money(l.total, c)}</td>
            </tr>
          ))}</tbody>
        </table>
        <div className="ml-auto mt-4 w-64 space-y-0.5">
          <div className="flex justify-between"><span>Taxable value</span><span>{money(s.totals.taxable, c)}</span></div>
          <div className="flex justify-between"><span>Tax</span><span>{money(s.totals.tax, c)}</span></div>
          <div className="flex justify-between border-t pt-1 text-base font-extrabold" style={{ borderColor: "#111" }}><span>Credit total</span><span>{money(s.totals.total, c)}</span></div>
        </div>
        <div className="mt-8 flex justify-between text-[11px]"><span>Received by</span><span>For {s.property.legal_name}</span></div>
        <p className="mt-2 text-[10px]" style={{ color: "#666" }}>This is a computer-generated credit note.</p>
      </div>
    </div>
  );
}
