import Link from "next/link";
import { redirect } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";
import { STATUS_LABEL, type Folio } from "@/lib/fo";
import { PrintButton } from "../../../../print-button";

/** The guest's folio statement: every charge and payment, voided lines marked. This is a statement, not a tax invoice. */
export default async function StatementPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) redirect("/front-office");
  const user = await requireUser();
  if (!has(user, "front_office") || !(can(user, "fo.view") || can(user, "fo.manage"))) redirect("/front-office");
  const { data } = await (await createClient()).rpc("fo_folio", { p_stay: id });
  const f = data as unknown as Folio | null;
  if (!f) redirect(`/front-office/stay/${id}`);
  const c = user.currency_code;
  const { stay, totals } = f;
  return (
    <div className="mx-auto max-w-3xl">
      <div className="no-print mb-3 flex items-center justify-between gap-3">
        <Link href={`/front-office/stay/${id}`} className="text-sm underline">← Folio</Link>
        <div className="w-44"><PrintButton label="Print statement" /></div>
      </div>
      <div className="report-root card p-6 text-[13px] leading-snug" style={{ background: "#fff", color: "#111" }}>
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <div className="text-lg font-extrabold">Guest statement</div>
            <div className="font-semibold">{stay.guest.full_name}</div>
            <div>Stay #{stay.stay_no}{stay.room_number ? ` · Room ${stay.room_number}` : ""} · {stay.room_type}</div>
            <div>{stay.arrival} to {stay.departure} · {stay.nights} night{stay.nights === 1 ? "" : "s"} · {STATUS_LABEL[stay.status]}</div>
          </div>
          <div className="text-right text-xs" style={{ color: "#555" }}>Not a tax invoice</div>
        </div>
        <table className="mt-4 w-full border-collapse text-[12px]">
          <thead><tr style={{ borderTop: "1px solid #111", borderBottom: "1px solid #111" }}><th className="py-1 text-left">Date</th><th className="text-left">Charge</th><th className="text-right">Before tax</th><th className="text-right">Tax</th><th className="text-right">Amount</th></tr></thead>
          <tbody>
            {f.charges.map((x) => (
              <tr key={x.charge_id} style={{ borderBottom: "1px solid #ddd", ...(x.voided ? { textDecoration: "line-through", color: "#777" } : {}) }}>
                <td className="py-1">{x.on}</td><td>{x.description}{x.voided && x.void_reason ? ` (void: ${x.void_reason})` : ""}</td>
                <td className="text-right">{money(x.net_amount, c)}</td><td className="text-right">{money(x.tax_amount, c)}</td><td className="text-right">{money(x.total, c)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <table className="mt-4 w-full border-collapse text-[12px]">
          <thead><tr style={{ borderTop: "1px solid #111", borderBottom: "1px solid #111" }}><th className="py-1 text-left">Date</th><th className="text-left">Payment</th><th className="text-right">Amount</th></tr></thead>
          <tbody>
            {f.payments.length === 0 && <tr><td className="py-1" colSpan={3}>No payments.</td></tr>}
            {f.payments.map((p) => (
              <tr key={p.payment_id} style={{ borderBottom: "1px solid #ddd", ...(p.voided ? { textDecoration: "line-through", color: "#777" } : {}) }}>
                <td className="py-1">{p.on}</td><td>{p.is_refund ? "Refund" : "Payment"} · {p.method}{p.voided && p.void_reason ? ` (void: ${p.void_reason})` : ""}</td>
                <td className="text-right">{p.is_refund ? "-" : ""}{money(p.amount, c)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <div className="ml-auto mt-4 w-64 space-y-0.5">
          <div className="flex justify-between"><span>Charged</span><span>{money(totals.charged, c)}</span></div>
          <div className="flex justify-between"><span>Paid</span><span>{money(totals.paid, c)}</span></div>
          {totals.refunded > 0 && <div className="flex justify-between"><span>Refunded</span><span>{money(totals.refunded, c)}</span></div>}
          <div className="flex justify-between border-t pt-1 text-base font-extrabold" style={{ borderColor: "#111" }}><span>{totals.balance > 0 ? "Balance due" : totals.balance < 0 ? "In credit" : "Settled"}</span><span>{money(Math.abs(totals.balance), c)}</span></div>
        </div>
      </div>
    </div>
  );
}
