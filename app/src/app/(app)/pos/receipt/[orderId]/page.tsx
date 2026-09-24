import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { ReceiptView, type ReceiptData } from "../../receipt-view";

export default async function ReceiptPage({
  params,
}: {
  params: Promise<{ orderId: string }>;
}) {
  const { orderId } = await params;
  const supabase = await createClient();

  // RLS scopes this to the signed-in user's restaurant, so a bill from another
  // restaurant simply is not found.
  const { data: order } = await supabase
    .from("orders")
    .select(
      "id, bill_number, order_type, created_at, subtotal, discount_total, tax_total, rounding_adjustment, grand_total, cashier_id, branch_id, currency_code",
    )
    .eq("id", orderId)
    .maybeSingle();

  if (!order) notFound();

  const [{ data: items }, { data: taxes }, { data: payment }, { data: restaurant }, { data: branch }, { data: settings }, { data: cashier }] =
    await Promise.all([
      supabase
        .from("order_items")
        .select("product_name, quantity, unit_price, line_total, created_at")
        .eq("order_id", order.id)
        .order("created_at"),
      supabase.from("order_item_taxes").select("component_name, rate, tax_amount").eq("order_id", order.id),
      supabase
        .from("payments")
        .select("amount, tendered_amount, change_amount, payment_method_id")
        .eq("order_id", order.id)
        .maybeSingle(),
      supabase.from("restaurants").select("legal_name, trading_name, tax_registration_no, currency_code").limit(1).maybeSingle(),
      supabase.from("branches").select("name, address_line1, address_line2, city, phone").eq("id", order.branch_id).maybeSingle(),
      supabase.from("branch_settings").select("receipt_header, receipt_footer").limit(1).maybeSingle(),
      supabase.from("users").select("full_name").eq("id", order.cashier_id).maybeSingle(),
    ]);

  // Aggregate frozen tax components into one line per component (CGST, SGST…).
  const taxMap = new Map<string, number>();
  for (const t of taxes ?? []) {
    const key = `${t.component_name} (${Number(t.rate)}%)`;
    taxMap.set(key, Math.round(((taxMap.get(key) ?? 0) + Number(t.tax_amount)) * 100) / 100);
  }
  const taxLines = Array.from(taxMap, ([name, amount]) => ({ name, amount }));

  let methodName = "Paid";
  if (payment?.payment_method_id) {
    const { data: m } = await supabase
      .from("payment_methods")
      .select("name")
      .eq("id", payment.payment_method_id)
      .maybeSingle();
    methodName = m?.name ?? "Paid";
  }

  const address =
    [branch?.address_line1, branch?.address_line2, branch?.city].filter(Boolean).join(", ") || null;

  const data: ReceiptData = {
    header: settings?.receipt_header || restaurant?.trading_name || "SNA POS",
    legalName: restaurant?.legal_name ?? "",
    gstin: restaurant?.tax_registration_no ?? null,
    branchName: branch?.name ?? "",
    address,
    phone: branch?.phone ?? null,
    billNumber: order.bill_number,
    orderType: order.order_type,
    createdAt: order.created_at,
    currency: order.currency_code ?? restaurant?.currency_code ?? "INR",
    cashierName: cashier?.full_name ?? "—",
    items: (items ?? []).map((it) => ({
      name: it.product_name,
      qty: Number(it.quantity),
      unitPrice: Number(it.unit_price),
      lineTotal: Number(it.line_total),
    })),
    taxLines,
    subtotal: Number(order.subtotal),
    discount: Number(order.discount_total),
    taxTotal: Number(order.tax_total),
    rounding: Number(order.rounding_adjustment),
    grandTotal: Number(order.grand_total),
    payment: payment
      ? {
          methodName,
          tendered: payment.tendered_amount != null ? Number(payment.tendered_amount) : null,
          change: Number(payment.change_amount),
        }
      : null,
    footer: settings?.receipt_footer ?? null,
  };

  return <ReceiptView data={data} />;
}
