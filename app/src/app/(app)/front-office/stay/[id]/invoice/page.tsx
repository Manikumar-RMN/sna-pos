import Link from "next/link";
import { redirect } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import type { InvoiceState } from "@/lib/fo";
import { PrintButton } from "../../../../print-button";

/** The issued GST tax invoice for a stay, laid out for A4. */
export default async function InvoicePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) redirect("/front-office");
  const user = await requireUser();
  if (!has(user, "front_office") || !(can(user, "fo.view") || can(user, "fo.manage"))) redirect("/front-office");
  const { data } = await (await createClient()).rpc("fo_invoice_for_stay", { p_stay: id });
  const inv = data as unknown as InvoiceState | null;
  if (!inv || !inv.issued) redirect(`/front-office/stay/${id}`);
  const s = inv.snapshot;
  const c = user.currency_code;
  const intra = s.supply.type === "intra";

  return (
    <div className="mx-auto max-w-3xl">
      <div className="no-print mb-3 flex items-center justify-between gap-3">
        <Link href={`/front-office/stay/${id}`} className="text-sm underline">← Folio</Link>
        <div className="w-40"><PrintButton label="Print invoice" /></div>
      </div>
      <div className="report-root card p-6 text-[13px] leading-snug" style={{ background: "#fff", color: "#111" }}>
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div className="text-lg font-extrabold">{s.property.legal_name}</div>
            <div className="whitespace-pre-line">{s.property.address}</div>
            {s.property.phone && <div>Tel {s.property.phone}</div>}
            {s.property.email && <div>{s.property.email}</div>}
            {s.property.gstin && <div className="font-semibold">GSTIN {s.property.gstin}</div>}
          </div>
          <div className="text-right">
            <div className="text-lg font-extrabold tracking-wide">TAX INVOICE</div>
            <div>No. <b>{inv.invoice_no}</b></div>
            <div>Date {inv.invoice_date}</div>
          </div>
        </div>

        <div className="mt-4 grid gap-4 sm:grid-cols-2">
          <div>
            <div className="text-xs font-bold uppercase" style={{ color: "#555" }}>Billed to</div>
            <div className="font-semibold">{s.bill_to.name}</div>
            {s.bill_to.address && <div className="whitespace-pre-line">{s.bill_to.address}</div>}
            {s.bill_to.gstin && <div>GSTIN {s.bill_to.gstin}</div>}
            {s.bill_to.state_code && <div>State code {s.bill_to.state_code}</div>}
            {s.guest.name !== s.bill_to.name && <div className="mt-1">Guest: {s.guest.name}</div>}
          </div>
          <div>
            <div className="text-xs font-bold uppercase" style={{ color: "#555" }}>Stay</div>
            <div>Stay #{s.stay.stay_no}{s.stay.room_number ? ` · Room ${s.stay.room_number}` : ""}{s.stay.room_type ? ` (${s.stay.room_type})` : ""}</div>
            <div>{s.stay.arrival} to {s.stay.departure} · {s.stay.nights} night{s.stay.nights === 1 ? "" : "s"}</div>
            <div>{s.stay.adults} adult{s.stay.adults === 1 ? "" : "s"}{s.stay.children ? `, ${s.stay.children} child${s.stay.children === 1 ? "" : "ren"}` : ""}{s.stay.rate_plan ? ` · ${s.stay.rate_plan}` : ""}</div>
            <div>Place of supply: state code {s.supply.place_of_supply_state_code ?? "—"} · Reverse charge: {s.supply.reverse_charge ? "Yes" : "No"}</div>
          </div>
        </div>

        <table className="mt-4 w-full border-collapse text-[12px]">
          <thead>
            <tr style={{ borderBottom: "1px solid #111", borderTop: "1px solid #111" }}>
              <th className="py-1 text-left">Date</th><th className="text-left">Description</th><th className="text-left">SAC</th>
              <th className="text-right">Qty</th><th className="text-right">Taxable</th><th className="text-right">Tax %</th><th className="text-right">Tax</th><th className="text-right">Amount</th>
            </tr>
          </thead>
          <tbody>
            {s.lines.map((l, i) => (
              <tr key={i} style={{ borderBottom: "1px solid #ddd" }}>
                <td className="py-1">{l.on}</td><td>{l.description}</td><td>{l.sac}</td>
                <td className="text-right">{l.quantity}</td><td className="text-right">{money(l.taxable, c)}</td>
                <td className="text-right">{l.tax_pct}</td><td className="text-right">{money(l.tax, c)}</td><td className="text-right">{money(l.total, c)}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <div className="mt-4 grid gap-4 sm:grid-cols-2">
          <div>
            <div className="text-xs font-bold uppercase" style={{ color: "#555" }}>Tax summary</div>
            <table className="mt-1 w-full border-collapse text-[12px]">
              <thead>
                <tr style={{ borderBottom: "1px solid #111" }}>
                  <th className="text-left">SAC</th><th className="text-right">Rate</th><th className="text-right">Taxable</th>
                  {intra ? <><th className="text-right">CGST</th><th className="text-right">SGST</th></> : <th className="text-right">Tax</th>}
                </tr>
              </thead>
              <tbody>
                {s.tax_summary.map((t, i) => (
                  <tr key={i}>
                    <td>{t.sac}</td><td className="text-right">{t.tax_pct}%</td><td className="text-right">{money(t.taxable, c)}</td>
                    {intra ? <><td className="text-right">{money(t.cgst, c)}</td><td className="text-right">{money(t.sgst, c)}</td></> : <td className="text-right">{money(t.tax, c)}</td>}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="space-y-0.5">
            <div className="flex justify-between"><span>Taxable value</span><span>{money(s.totals.taxable, c)}</span></div>
            <div className="flex justify-between"><span>Tax</span><span>{money(s.totals.tax, c)}</span></div>
            <div className="flex justify-between border-t pt-1 text-base font-extrabold" style={{ borderColor: "#111" }}><span>Invoice total</span><span>{money(s.totals.total, c)}</span></div>
          </div>
        </div>

        {s.payments.length > 0 && (
          <div className="mt-4">
            <div className="text-xs font-bold uppercase" style={{ color: "#555" }}>Received</div>
            <ul className="mt-1">
              {s.payments.map((p, i) => (
                <li key={i} className="flex justify-between"><span>{p.on} · {p.is_refund ? "Refund" : "Payment"} · {p.method}{p.reference ? ` · ${p.reference}` : ""}</span><span>{p.is_refund ? "-" : ""}{money(p.amount, c)}</span></li>
              ))}
            </ul>
          </div>
        )}

        {s.property.footer && <p className="mt-4 text-center text-[11px]">{s.property.footer}</p>}
        <div className="mt-8 flex justify-between text-[11px]"><span>Guest signature</span><span>For {s.property.legal_name}</span></div>
        <p className="mt-2 text-[10px]" style={{ color: "#666" }}>This is a computer-generated invoice.</p>
      </div>
    </div>
  );
}
