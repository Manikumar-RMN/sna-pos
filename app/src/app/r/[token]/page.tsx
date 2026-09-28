import type { Metadata } from "next";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/format";

export const metadata: Metadata = { title: "Your bill", robots: { index: false } };
export const dynamic = "force-dynamic";

type EBill = {
  restaurant: string;
  legal_name: string | null;
  outlet: string;
  address: string | null;
  tax_label: string;
  tax_no: string | null;
  fssai: string | null;
  title: string;
  footer: string | null;
  bill_number: string;
  date: string;
  currency: string;
  status: string;
  payment_status: string;
  buyer_gstin: string | null;
  buyer_name: string | null;
  items: { name: string; local: string | null; options: string | null; qty: number; amount: number }[];
  taxes: { name: string; amount: number }[];
  subtotal: number;
  discount: number;
  service_charge: number;
  rounding: number;
  tax_included: number;
  grand_total: number;
  paid: number;
};

/** The e-bill a guest opens from the WhatsApp link. The long random link is the only key. */
export default async function EBillPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  const supabase = await createClient();
  const { data } = await supabase.rpc("public_receipt", { p_token: token });
  const b = data as unknown as EBill | null;
  if (!b) {
    return (
      <main className="grid min-h-screen place-items-center p-6 text-center">
        <div className="card max-w-sm p-6">
          <h1 className="text-lg font-bold">Bill not found</h1>
          <p className="mt-2 text-sm" style={{ color: "var(--color-ink-3)" }}>Please check the link or ask the restaurant.</p>
        </div>
      </main>
    );
  }
  const m = (n: number) => money(n, b.currency);
  const Row = ({ label, value, strong }: { label: string; value: string; strong?: boolean }) => (
    <div className={`flex justify-between ${strong ? "text-base font-bold" : ""}`}>
      <span>{label}</span>
      <span className="tabular-nums">{value}</span>
    </div>
  );
  return (
    <main className="mx-auto max-w-md p-4">
      <article className="card p-5 text-sm">
        <header className="mb-3 text-center">
          <h1 className="font-display text-xl font-bold">{b.restaurant}</h1>
          {b.legal_name && b.legal_name !== b.restaurant && <div>{b.legal_name}</div>}
          <div>{b.outlet}</div>
          {b.address && <div>{b.address}</div>}
          {b.tax_no && <div>{b.tax_label}: {b.tax_no}</div>}
          {b.fssai && <div>FSSAI: {b.fssai}</div>}
          <div className="mt-2 font-bold uppercase tracking-wide">{b.title}</div>
        </header>
        {b.status === "voided" && (
          <div className="mb-3 rounded-xl px-3 py-2 text-center font-bold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
            This bill was cancelled.
          </div>
        )}
        <div className="mb-2 flex justify-between">
          <span>Bill {b.bill_number}</span>
          <span>{b.date}</span>
        </div>
        {b.buyer_gstin && <div className="mb-2">Customer: {b.buyer_name ?? ""} · GSTIN {b.buyer_gstin}</div>}
        <ul className="space-y-1.5 border-y py-2" style={{ borderColor: "var(--color-line)" }}>
          {b.items.map((i, k) => (
            <li key={k} className="flex justify-between gap-3">
              <div>
                {Number(i.qty)} × {i.name}
                {i.local && <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>{i.local}</div>}
                {i.options && <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>{i.options}</div>}
              </div>
              <span className="tabular-nums">{m(Number(i.amount))}</span>
            </li>
          ))}
        </ul>
        <div className="mt-2 space-y-1">
          <Row label="Items" value={m(Number(b.subtotal))} />
          {Number(b.discount) > 0 && <Row label="Discount" value={`− ${m(Number(b.discount))}`} />}
          {Number(b.service_charge) > 0 && <Row label="Service charge" value={m(Number(b.service_charge))} />}
          {b.taxes.map((t, k) => (
            <Row key={k} label={Number(b.tax_included) > 0 ? `Includes ${t.name}` : t.name} value={m(Number(t.amount))} />
          ))}
          {Number(b.rounding) !== 0 && <Row label="Rounding" value={m(Number(b.rounding))} />}
          <Row label="Total" value={m(Number(b.grand_total))} strong />
          <Row label={b.payment_status === "paid" ? "Paid" : "Paid so far"} value={m(Number(b.paid))} />
        </div>
        {b.footer && <p className="mt-4 whitespace-pre-line text-center">{b.footer}</p>}
      </article>
      <p className="mt-3 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>Powered by SNA POS</p>
    </main>
  );
}
