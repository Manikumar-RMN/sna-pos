import Link from "next/link";
import { redirect } from "next/navigation";
import { can, requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { billFormat } from "@/lib/bill-format";
import type { ReceiptData } from "@/app/(app)/pos/receipt-view";
import { NoAccess, SectionHead } from "../section-head";
import { BillLayout } from "./bill-layout";
import { BillNumbers, type BillPrefixInfo } from "./bill-numbers";

/** Sample prices are written for rupees; this keeps them believable in other currencies. */
const PRICE_SCALE: Record<string, number> = { IDR: 250, VND: 300, KRW: 20, JPY: 2, AED: 0.2, SGD: 0.1, MYR: 0.1 };

const r2 = (n: number) => Math.round(n * 100) / 100;

export default async function BillLayoutSettings({ searchParams }: { searchParams: Promise<{ print?: string }> }) {
  const user = await requireUser();
  if (!can(user, "settings.manage")) return <NoAccess />;
  // The preview is the real bill, and the real bill prints by itself when the
  // address ends in ?print=1. A preview must never print, so that is dropped here.
  if ((await searchParams).print !== undefined) redirect("/settings/bill");

  const supabase = await createClient();
  const isIndia = user.country_code === "IN";
  const [{ data: rest }, { data: branch }, { data: bs }, { data: country }, { data: upiMethod }, { data: prefixInfo }] = await Promise.all([
    supabase.from("restaurants").select("legal_name, trading_name, tax_registration_no, fssai_no, sac_code, logo_url").limit(1).maybeSingle(),
    supabase.from("branches").select("name, address_line1, address_line2, city, phone").eq("id", user.branch_id).maybeSingle(),
    supabase.from("branch_settings").select("receipt_header, receipt_footer, bill_format").eq("branch_id", user.branch_id).maybeSingle(),
    supabase.from("countries").select("tax_id_label, tax_system_name, invoice_title, has_senior_discount").eq("code", user.country_code).maybeSingle(),
    isIndia
      ? supabase.from("payment_methods").select("upi_id").eq("kind", "upi").eq("is_active", true).not("upi_id", "is", null).limit(1).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.rpc("bill_prefix_info"),
  ]);

  // A made-up takeaway bill, under the restaurant's real name, address and tax details.
  const k = PRICE_SCALE[user.currency_code] ?? 1;
  const items = [
    { name: "Masala Dosa", qty: 2, unitPrice: r2(90 * k) },
    { name: "Filter Coffee", qty: 2, unitPrice: r2(30 * k) },
    { name: "Idli (2 pcs)", qty: 1, unitPrice: r2(50 * k) },
  ].map((it) => ({ ...it, local: null, options: null, amount: r2(it.qty * it.unitPrice) }));
  const subtotal = r2(items.reduce((s, it) => s + it.amount, 0));
  const tax = r2(subtotal * 0.05);
  const half = r2(tax / 2);
  const taxName = country?.tax_system_name ?? "Tax";
  const grandTotal = r2(subtotal + tax);
  const tendered = r2(Math.ceil(grandTotal / (100 * k)) * 100 * k);
  const tradingName = rest?.trading_name || user.trading_name;

  const sample: ReceiptData = {
    invoiceTitle: country?.invoice_title ?? null,
    header: bs?.receipt_header || tradingName || "SNA POS",
    legalName: rest?.legal_name ?? "",
    taxIdLabel: country?.tax_id_label ?? "Tax No.",
    taxId: rest?.tax_registration_no ?? null,
    branchName: branch?.name ?? user.branch_name,
    address: [branch?.address_line1, branch?.address_line2, branch?.city].filter(Boolean).join(", ") || null,
    phone: branch?.phone ?? null,
    billNumber: (prefixInfo as BillPrefixInfo | null)?.next_number ?? "SAMPLE-0042",
    orderType: "takeaway",
    tableNumber: null,
    createdAt: new Date().toISOString(),
    timezone: user.timezone,
    currency: user.currency_code,
    cashierName: user.full_name,
    items,
    taxLines: isIndia
      ? [
          { name: "CGST (2.5%)", amount: half },
          { name: "SGST (2.5%)", amount: r2(tax - half) },
        ]
      : [{ name: `${taxName} (5%)`, amount: tax }],
    subtotal,
    discount: 0,
    serviceCharge: 0,
    serviceChargeLabel: "Service charge",
    taxTotal: tax,
    taxIncluded: 0,
    rounding: 0,
    grandTotal,
    netSales: subtotal,
    senior: null,
    seniorDiscount: 0,
    vatRemoved: 0,
    exemptSales: 0,
    showVatBreakdown: !!country?.has_senior_discount,
    payments: [{ methodName: "Cash", amount: grandTotal, tendered, change: r2(tendered - grandTotal), cashRounding: 0 }],
    balance: 0,
    refunded: 0,
    state: "paid",
    voidReason: null,
    footer: bs?.receipt_footer ?? null,
    fssaiNo: isIndia ? (rest?.fssai_no ?? null) : null,
    sacCode: isIndia ? (rest?.sac_code ?? null) : null,
    buyer: null,
    upi: isIndia && upiMethod?.upi_id ? { id: upiMethod.upi_id, payee: tradingName || "Restaurant" } : null,
    guest: { name: "Priya", phone: isIndia ? "919876543210" : null, address: null },
    token: 12,
  };

  return (
    <div>
      <SectionHead title="Bill layout">
        Bill numbers, and how the printed bill and the kitchen ticket look. The heading and footer lines of the bill are typed in{" "}
        <Link href="/settings/company" className="font-semibold underline" style={{ color: "var(--color-brand)" }}>
          Company
        </Link>
        .
      </SectionHead>
      {prefixInfo && <BillNumbers info={prefixInfo as unknown as BillPrefixInfo} isIndia={isIndia} />}
      <BillLayout
        initialFormat={billFormat(bs?.bill_format)}
        initialLogo={rest?.logo_url || null}
        sample={sample}
        isIndia={isIndia}
        hasUpiId={!!upiMethod?.upi_id}
        severalOutlets={user.outlet_count > 1}
      />
    </div>
  );
}
