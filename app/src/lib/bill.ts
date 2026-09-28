import { createClient } from "@/lib/supabase/server";
import { billState } from "@/lib/format";
import type { ReceiptData } from "@/app/(app)/pos/receipt-view";

export type BillDetail = {
  id: string;
  receipt: ReceiptData;
  status: string;
  paymentStatus: string;
  paidTotal: number;
  refunded: number;
  refunds: { amount: number; reason: string; at: string; by: string }[];
  voidedBy: string | null;
  voidedAt: string | null;
  cashRoundingMode: string;
  /** Still to pay (unpaid / part-paid bills). */
  balance: number;
  /** Items still on the bill, for cancel / split. */
  lines: { id: string; name: string; options: string | null; qty: number; amount: number }[];
  cancelled: { name: string; qty: number; reason: string | null }[];
  tableId: string | null;
  hasDiscount: boolean;
  mergedInto: string | null;
  /** Payments on the bill, for "change payment mode". */
  /** The bill's business day is closed: no void or change, only a credit note. */
  dayClosed: boolean;
  businessDate: string | null;
  creditNotes: { id: string; number: string; amount: number; at: string; reason: string }[];
  paymentList: { id: string; methodId: string; methodName: string; amount: number; rounded: boolean }[];
  /** Discount and service charge as they stand on an open bill. */
  adjust: { discount: number; scAvailable: boolean; scOn: boolean; scPercent: number; scLabel: string; senior: boolean };
};

/**
 * Everything needed to show one bill. Row Level Security scopes every read to
 * the signed-in user's restaurant, so a bill from another restaurant is simply
 * not found. No amount is recalculated here: every figure is the one frozen on
 * the bill when it was saved.
 */
export async function getBill(orderId: string): Promise<BillDetail | null> {
  if (!/^[0-9a-f-]{36}$/i.test(orderId)) return null;
  const supabase = await createClient();

  const { data: order } = await supabase
    .from("orders")
    .select(
      "id, bill_number, order_type, created_at, subtotal, discount_total, tax_total, tax_included, tax_exempt_amount, exempt_sales, service_charge, rounding_adjustment, grand_total, paid_total, status, payment_status, void_reason, voided_at, voided_by, cashier_id, branch_id, dining_table_id, currency_code, senior_details, merged_into, calc_params, business_date",
    )
    .eq("id", orderId)
    .maybeSingle();
  if (!order) return null;

  const [items, taxes, payments, refunds, restaurant, branch, settings, table, discounts, upiMethod, day, creditNotes] = await Promise.all([
    supabase
      .from("order_items")
      .select("id, product_name, options_text, quantity, unit_price, line_subtotal, net_amount, created_at, cancelled_at, cancelled_qty, cancel_reason")
      .eq("order_id", order.id)
      .order("created_at")
      .order("id"),
    supabase.from("order_item_taxes").select("component_name, rate, tax_amount").eq("order_id", order.id),
    supabase
      .from("payments")
      .select("id, amount, tendered_amount, change_amount, rounding_adjustment, payment_method_id, created_at")
      .eq("order_id", order.id)
      .in("status", ["captured", "refunded"])
      .order("created_at"),
    supabase.from("refunds").select("amount, reason, created_at, approved_by").eq("order_id", order.id).order("created_at"),
    supabase
      .from("restaurants")
      .select("legal_name, trading_name, tax_registration_no, currency_code, timezone, country_code")
      .limit(1)
      .maybeSingle(),
    supabase.from("branches").select("name, address_line1, address_line2, city, phone").eq("id", order.branch_id).maybeSingle(),
    supabase
      .from("branch_settings")
      .select("receipt_header, receipt_footer, service_charge_label, service_charge_percent, cash_rounding_mode, rounding_cash_only")
      .eq("branch_id", order.branch_id)
      .maybeSingle(),
    order.dining_table_id
      ? supabase.from("dining_tables").select("table_number").eq("id", order.dining_table_id).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("order_discounts").select("discount_type, amount").eq("order_id", order.id),
    supabase.from("payment_methods").select("upi_id").eq("kind", "upi").eq("is_active", true).not("upi_id", "is", null).limit(1).maybeSingle(),
    order.business_date
      ? supabase.from("business_days").select("status").eq("branch_id", order.branch_id).eq("business_date", order.business_date).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from("credit_notes").select("id, number, amount, created_at, reason").eq("order_id", order.id).order("created_at"),
  ]);

  const { data: country } = restaurant.data?.country_code
    ? await supabase
        .from("countries")
        .select("tax_id_label, invoice_title, has_senior_discount")
        .eq("code", restaurant.data.country_code)
        .maybeSingle()
    : { data: null };

  const peopleIds = [order.cashier_id, order.voided_by, ...(refunds.data ?? []).map((r) => r.approved_by)].filter(
    Boolean,
  ) as string[];
  const { data: people } = peopleIds.length
    ? await supabase.from("users").select("id, full_name").in("id", peopleIds)
    : { data: [] as { id: string; full_name: string }[] };
  const nameOf = (id: string | null) => (people ?? []).find((p) => p.id === id)?.full_name ?? "—";

  const paymentRows = payments.data ?? [];
  const methodIds = [...new Set(paymentRows.map((p) => p.payment_method_id))];
  const { data: methodRows } = methodIds.length
    ? await supabase.from("payment_methods").select("id, name").in("id", methodIds)
    : { data: [] as { id: string; name: string }[] };
  const methodName = (id: string) => (methodRows ?? []).find((m) => m.id === id)?.name ?? "Paid";
  const covered = paymentRows.reduce((s, p) => s + Number(p.amount) - Number(p.rounding_adjustment ?? 0), 0);
  const balance = Math.max(0, Math.round((Number(order.grand_total) - covered) * 100) / 100);
  const liveItems = (items.data ?? []).filter((it) => !it.cancelled_at);

  const taxMap = new Map<string, number>();
  for (const t of taxes.data ?? []) {
    if (Number(t.tax_amount) === 0) continue;
    const key = `${t.component_name} (${Number(t.rate)}%)`;
    taxMap.set(key, Math.round(((taxMap.get(key) ?? 0) + Number(t.tax_amount)) * 100) / 100);
  }

  const refundList = (refunds.data ?? []).map((r) => ({
    amount: Number(r.amount),
    reason: r.reason,
    at: r.created_at,
    by: nameOf(r.approved_by),
  }));
  const refunded = Math.round(refundList.reduce((s, r) => s + r.amount, 0) * 100) / 100;
  const seniorDiscount = (discounts.data ?? [])
    .filter((d) => d.discount_type === "senior_pwd")
    .reduce((s, d) => s + Number(d.amount), 0);
  const sd = order.senior_details as { kind?: string; name?: string; id_no?: string } | null;

  const b = branch.data;
  const address = [b?.address_line1, b?.address_line2, b?.city].filter(Boolean).join(", ") || null;
  const tz = restaurant.data?.timezone ?? "Asia/Kolkata";

  const receipt: ReceiptData = {
    invoiceTitle: country?.invoice_title ?? null,
    header: settings.data?.receipt_header || restaurant.data?.trading_name || "SNA POS",
    legalName: restaurant.data?.legal_name ?? "",
    taxIdLabel: country?.tax_id_label ?? "Tax No.",
    taxId: restaurant.data?.tax_registration_no ?? null,
    branchName: b?.name ?? "",
    address,
    phone: b?.phone ?? null,
    billNumber: order.bill_number,
    orderType: order.order_type,
    tableNumber: (table.data as { table_number: string } | null)?.table_number ?? null,
    createdAt: order.created_at,
    timezone: tz,
    currency: order.currency_code ?? restaurant.data?.currency_code ?? "INR",
    cashierName: nameOf(order.cashier_id),
    items: liveItems.map((it) => ({
      name: it.product_name,
      options: it.options_text,
      qty: Number(it.quantity),
      unitPrice: Number(it.unit_price),
      amount: Number(it.line_subtotal),
    })),
    taxLines: Array.from(taxMap, ([name, amount]) => ({ name, amount })),
    subtotal: Number(order.subtotal),
    discount: Math.round((Number(order.discount_total) - seniorDiscount) * 100) / 100,
    serviceCharge: Number(order.service_charge),
    serviceChargeLabel: settings.data?.service_charge_label ?? "Service charge",
    taxTotal: Number(order.tax_total),
    taxIncluded: Number(order.tax_included),
    rounding: Number(order.rounding_adjustment),
    grandTotal: Number(order.grand_total),
    netSales: liveItems.reduce((s, it) => s + Number(it.net_amount), 0),
    senior: sd?.name ? { kind: sd.kind ?? "senior", name: sd.name, idNo: sd.id_no ?? "" } : null,
    seniorDiscount,
    vatRemoved: Number(order.tax_exempt_amount),
    exemptSales: Number(order.exempt_sales),
    showVatBreakdown: !!country?.has_senior_discount,
    payments: paymentRows.map((p) => ({
      methodName: methodName(p.payment_method_id),
      amount: Number(p.amount),
      tendered: p.tendered_amount != null ? Number(p.tendered_amount) : null,
      change: Number(p.change_amount ?? 0),
      cashRounding: Number(p.rounding_adjustment ?? 0),
    })),
    balance,
    refunded,
    state: billState(order.status, order.payment_status),
    voidReason: order.void_reason,
    footer: settings.data?.receipt_footer ?? null,
    upi:
      restaurant.data?.country_code === "IN" && upiMethod.data?.upi_id
        ? { id: upiMethod.data.upi_id, payee: restaurant.data?.trading_name ?? "Restaurant" }
        : null,
  };

  return {
    id: order.id,
    receipt,
    status: order.status,
    paymentStatus: order.payment_status,
    paidTotal: Number(order.paid_total),
    refunded,
    refunds: refundList,
    voidedBy: order.voided_by ? nameOf(order.voided_by) : null,
    voidedAt: order.voided_at,
    cashRoundingMode: settings.data?.rounding_cash_only ? (settings.data?.cash_rounding_mode ?? "none") : "none",
    balance,
    lines: liveItems.map((it) => ({
      id: it.id,
      name: it.product_name,
      options: it.options_text,
      qty: Number(it.quantity),
      amount: Number(it.line_subtotal),
    })),
    cancelled: (items.data ?? [])
      .filter((it) => Number(it.cancelled_qty ?? 0) > 0)
      .map((it) => ({ name: it.product_name, qty: Number(it.cancelled_qty), reason: it.cancel_reason })),
    tableId: order.dining_table_id,
    hasDiscount: Number(order.discount_total) > 0 || !!sd?.name,
    mergedInto: order.merged_into,
    dayClosed: (day.data as { status?: string } | null)?.status === "closed",
    businessDate: order.business_date,
    creditNotes: (creditNotes.data ?? []).map((c) => ({ id: c.id, number: c.number, amount: Number(c.amount), at: c.created_at, reason: c.reason })),
    paymentList: paymentRows.map((p) => ({
      id: p.id,
      methodId: p.payment_method_id,
      methodName: methodName(p.payment_method_id),
      amount: Number(p.amount),
      rounded: Math.abs(Number(p.rounding_adjustment ?? 0)) >= 0.005,
    })),
    adjust: (() => {
      const cp = (order.calc_params ?? {}) as { discount?: number | string; sc_percent?: number | string };
      const scPercent = Number(settings.data?.service_charge_percent ?? 0);
      return {
        discount: Number(cp.discount ?? 0),
        scAvailable: scPercent > 0,
        scOn: Number(cp.sc_percent ?? 0) > 0,
        scPercent,
        scLabel: settings.data?.service_charge_label ?? "Service charge",
        senior: !!sd?.name,
      };
    })(),
  };
}
