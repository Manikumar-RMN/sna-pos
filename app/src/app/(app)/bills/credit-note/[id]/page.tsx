import Link from "next/link";
import { notFound } from "next/navigation";
import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { dateTime, money } from "@/lib/format";
import { PrintButton } from "../../../print-button";

/** A credit note (credit memo / tax credit note): money given back on a paid bill, dated when it was issued. */
export default async function CreditNotePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) notFound();
  const user = await requireUser();
  const supabase = await createClient();
  const { data: cn } = await supabase
    .from("credit_notes")
    .select("id, number, business_date, amount, tax_amount, taxes, reason, created_at, order_id, payment_method_id, created_by, branch_id")
    .eq("id", id)
    .maybeSingle();
  if (!cn) notFound();
  const [{ data: order }, { data: rest }, { data: branch }, { data: method }, { data: by }] = await Promise.all([
    supabase.from("orders").select("bill_number, business_date, created_at, grand_total").eq("id", cn.order_id).maybeSingle(),
    supabase.from("restaurants").select("legal_name, trading_name, tax_registration_no, country_code").limit(1).maybeSingle(),
    supabase.from("branches").select("name, address_line1, city, phone").eq("id", cn.branch_id).maybeSingle(),
    supabase.from("payment_methods").select("name").eq("id", cn.payment_method_id).maybeSingle(),
    supabase.from("users").select("full_name").eq("id", cn.created_by).maybeSingle(),
  ]);
  const { data: country } = rest?.country_code
    ? await supabase.from("countries").select("tax_id_label").eq("code", rest.country_code).maybeSingle()
    : { data: null };
  const title =
    rest?.country_code === "AE" ? "TAX CREDIT NOTE" : rest?.country_code === "PH" ? "CREDIT MEMO" : "CREDIT NOTE";
  const c = user.currency_code;
  const taxes = (cn.taxes ?? []) as { name: string; rate: number; amount: number }[];

  return (
    <div className="mx-auto max-w-sm">
      <style>{`
        @media print {
          body * { visibility: hidden !important; }
          #receipt, #receipt * { visibility: visible !important; }
          #receipt { position: absolute; left: 0; top: 0; width: 80mm; border: 0 !important; box-shadow: none !important; }
          .no-print { display: none !important; }
        }
      `}</style>
      <div id="receipt" className="receipt card p-5 font-mono text-[12px] leading-snug" style={{ background: "#fff", color: "#111" }}>
        <div className="text-center">
          <div className="text-sm font-bold">{rest?.trading_name}</div>
          {rest?.legal_name && rest.legal_name !== rest.trading_name && <div>{rest.legal_name}</div>}
          <div>{[branch?.address_line1, branch?.city].filter(Boolean).join(", ")}</div>
          {branch?.phone && <div>Tel {branch.phone}</div>}
          {rest?.tax_registration_no && (
            <div>
              {country?.tax_id_label ?? "Tax No."} {rest.tax_registration_no}
            </div>
          )}
          <div className="mt-2 text-sm font-bold tracking-wide">{title}</div>
        </div>
        <div className="my-2 border-t border-dashed" style={{ borderColor: "#999" }} />
        <Row label="Number" value={cn.number} />
        <Row label="Date" value={dateTime(cn.created_at, user.timezone)} />
        <Row label="Against bill" value={order?.bill_number ?? "—"} />
        <Row label="Bill date" value={order ? dateTime(order.created_at, user.timezone) : "—"} />
        <Row label="Bill total" value={money(Number(order?.grand_total ?? 0), c)} />
        <div className="my-2 border-t border-dashed" style={{ borderColor: "#999" }} />
        <div>Reason: {cn.reason}</div>
        <div className="my-2 border-t border-dashed" style={{ borderColor: "#999" }} />
        <Row label="Value before tax" value={money(Number(cn.amount) - Number(cn.tax_amount), c)} />
        {taxes
          .filter((t) => Number(t.amount) !== 0)
          .map((t, i) => (
            <Row key={i} label={`${t.name} ${Number(t.rate)}% reversed`} value={money(Number(t.amount), c)} />
          ))}
        <div className="mt-1 flex justify-between text-sm font-bold">
          <span>Amount credited</span>
          <span>{money(Number(cn.amount), c)}</span>
        </div>
        <Row label="Given back by" value={method?.name ?? "—"} />
        <div className="my-2 border-t border-dashed" style={{ borderColor: "#999" }} />
        <div className="text-[11px]">Issued by {by?.full_name ?? "—"}</div>
        <div className="mt-4 border-t pt-0.5 text-center text-[10px]" style={{ borderColor: "#111" }}>
          Customer signature
        </div>
      </div>
      <div className="no-print mt-3 space-y-2">
        <PrintButton label="Print credit note" />
        <Link href={`/bills/${cn.order_id}`} className="btn w-full border text-sm" style={{ borderColor: "var(--color-line)" }}>
          Back to bill {order?.bill_number}
        </Link>
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-2">
      <span>{label}</span>
      <span className="whitespace-nowrap">{value}</span>
    </div>
  );
}
