import { notFound } from "next/navigation";
import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { orderTypeLabel } from "@/lib/format";
import { billFormat, paperWidth } from "@/lib/bill-format";
import { KotPrinter } from "./kot-printer";

/**
 * After KOT is pressed on the billing screen: sends the order's new items to the kitchen,
 * prints their kitchen ticket on this device (unless the device is set not to), then goes on
 * to the next order, or back to the bill when items were added to an open bill (?then=bill).
 * The bill is printed and paid later, from Bills or the table.
 */
export default async function KotPage({ params, searchParams }: { params: Promise<{ orderId: string }>; searchParams: Promise<{ then?: string }> }) {
  const user = await requireUser();
  const { orderId } = await params;
  const { then } = await searchParams;
  if (!/^[0-9a-f-]{36}$/i.test(orderId)) notFound();

  const supabase = await createClient();
  const [{ data: order }, { data: settings }] = await Promise.all([
    supabase.from("orders").select("id, bill_number, order_type, dining_table_id, token_no, guest_name").eq("id", orderId).maybeSingle(),
    supabase.from("branch_settings").select("bill_format").eq("branch_id", user.branch_id).maybeSingle(),
  ]);
  if (!order) notFound();
  const { data: table } = order.dining_table_id
    ? await supabase.from("dining_tables").select("table_number").eq("id", order.dining_table_id).maybeSingle()
    : { data: null as { table_number: string } | null };

  const type = orderTypeLabel[order.order_type ?? ""] ?? "";
  const guest = order.order_type === "takeaway" || order.order_type === "delivery" ? (order.guest_name ?? "").trim() : "";
  const where = table?.table_number ? `Table ${table.table_number}` : guest ? `${type} · ${guest}` : type;
  const format = billFormat(settings?.bill_format);

  return (
    <KotPrinter
      orderId={order.id}
      billNumber={order.bill_number}
      where={where}
      token={order.token_no ?? null}
      backToBill={then === "bill"}
      timezone={user.timezone}
      printMm={paperWidth(format).printMm}
      largePrint={format.kot_text === "large"}
    />
  );
}
