import { BillMissing } from "../../bill-missing";
import { requireUser } from "@/lib/auth";
import { can } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { getBill } from "@/lib/bill";
import { SettleScreen, type CheckCard, type PayMethod } from "./settle-screen";

/**
 * Winsar's Settlement screen: the open checks on the left, the payments being taken in the middle with a running
 * balance on the right, and Settle only when the balance reaches zero. The payments are held on this screen until
 * Settle is pressed, so a line can be taken off again — nothing reaches the database before that.
 */
export default async function SettlePage({ params }: { params: Promise<{ orderId: string }> }) {
  const { orderId } = await params;
  const user = await requireUser();
  const bill = await getBill(orderId);
  if (!bill) return <BillMissing />;
  const supabase = await createClient();

  const [{ data: methods }, { data: others }] = await Promise.all([
    supabase.from("payment_methods").select("id, name, kind, ask_reference").eq("is_active", true).not("kind", "in", "(gift_card,loyalty)").order("display_order"),
    bill.tableId
      ? supabase
          .from("orders")
          .select("id, bill_number, grand_total, paid_total, covers")
          .eq("dining_table_id", bill.tableId)
          .in("payment_status", ["unpaid", "partial"])
          .neq("status", "voided")
          .is("merged_into", null)
          .order("created_at")
      : Promise.resolve({ data: [] as never[] }),
  ]);

  const rows = (others ?? []) as unknown as { id: string; bill_number: string; grand_total: number; paid_total: number; covers: number | null }[];
  const checks: CheckCard[] = (rows.length ? rows : [{ id: bill.id, bill_number: bill.receipt.billNumber, grand_total: bill.receipt.grandTotal, paid_total: bill.paidTotal, covers: null }]).map((o) => ({
    id: o.id,
    billNumber: o.bill_number,
    amount: Number(o.grand_total),
    balance: Math.round((Number(o.grand_total) - Number(o.paid_total)) * 100) / 100,
    covers: o.covers ?? null,
  }));

  return (
    <SettleScreen
      orderId={bill.id}
      tableNumber={bill.receipt.tableNumber ?? null}
      currency={bill.receipt.currency}
      checks={checks}
      lines={bill.lines.map((l) => ({ name: l.name, qty: l.qty, amount: l.amount }))}
      value={bill.receipt.subtotal}
      discount={bill.receipt.discount}
      taxes={bill.receipt.taxTotal}
      total={bill.receipt.grandTotal}
      balance={bill.balance}
      methods={(methods ?? []).map((p) => ({ id: p.id, name: p.name, kind: p.kind, askReference: p.ask_reference })) as PayMethod[]}
      canPay={can(user, "payment.take")}
      dayClosed={bill.dayClosed}
    />
  );
}
