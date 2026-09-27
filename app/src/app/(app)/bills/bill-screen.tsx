import Link from "next/link";
import { notFound } from "next/navigation";
import { can, requireUser } from "@/lib/auth";
import { getBill } from "@/lib/bill";
import { createClient } from "@/lib/supabase/server";
import { dateTime, money } from "@/lib/format";
import { ReceiptView } from "../pos/receipt-view";
import { BillActions } from "./bill-actions";

/** One bill: printable receipt, its history, and the actions the user may take. */
export async function BillScreen({ orderId, from, splitPay = false }: { orderId: string; from: "pos" | "bills"; splitPay?: boolean }) {
  const user = await requireUser();
  const bill = await getBill(orderId);
  if (!bill) notFound();

  const r = bill.receipt;
  const tz = r.timezone;
  const open = r.state === "unpaid" || r.state === "part-paid";

  const supabase = await createClient();
  const [{ data: methods }, { data: shift }, { data: tables }, { data: openBills }, { data: mergedTo }] = await Promise.all([
    supabase.from("payment_methods").select("id, name, kind, ask_reference").eq("is_active", true).order("display_order"),
    supabase.from("shifts").select("id").eq("status", "open").limit(1).maybeSingle(),
    open
      ? supabase.from("dining_tables").select("id, table_number").eq("is_active", true).order("table_number")
      : Promise.resolve({ data: [] as { id: string; table_number: string }[] }),
    open
      ? supabase
          .from("orders")
          .select("id, bill_number, grand_total, dining_table_id, payment_status, discount_total, dining_tables(table_number)")
          .in("payment_status", ["unpaid", "partial"])
          .neq("status", "voided")
          .neq("id", bill.id)
          .order("created_at")
      : Promise.resolve({ data: [] as never[] }),
    bill.mergedInto
      ? supabase.from("orders").select("id, bill_number").eq("id", bill.mergedInto).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const busyTables = new Set((openBills ?? []).map((o) => o.dining_table_id).filter(Boolean));

  return (
    <div>
      {mergedTo && (
        <div className="no-print card mx-auto mb-3 max-w-sm p-3 text-sm">
          This bill was merged into{" "}
          <Link href={`/bills/${mergedTo.id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
            bill {mergedTo.bill_number}
          </Link>
          .
        </div>
      )}

      <ReceiptView
        data={r}
        backHref={from === "pos" ? "/pos" : "/bills"}
        backLabel={from === "pos" ? "New bill" : "All bills"}
        showNextBill={from === "pos" && !open}
      />

      {(bill.refunds.length > 0 || bill.voidedAt || bill.cancelled.length > 0) && (
        <div className="no-print card mx-auto mt-4 max-w-sm p-4 text-sm">
          <h2 className="mb-2 font-bold">History</h2>
          <ul className="space-y-1.5" style={{ color: "var(--color-ink-2)" }}>
            {bill.cancelled.map((c, i) => (
              <li key={`c${i}`}>
                Cancelled {c.qty} × {c.name}
                {c.reason ? ` — ${c.reason}` : ""}
              </li>
            ))}
            {bill.refunds.map((f, i) => (
              <li key={i}>
                Refund {money(f.amount, r.currency)} by {f.by}, {dateTime(f.at, tz)} — {f.reason}
              </li>
            ))}
            {bill.voidedAt && (
              <li>
                Voided by {bill.voidedBy}, {dateTime(bill.voidedAt, tz)} — {r.voidReason}
              </li>
            )}
          </ul>
        </div>
      )}

      <BillActions
        orderId={bill.id}
        billNumber={r.billNumber}
        state={r.state}
        grandTotal={r.grandTotal}
        balance={bill.balance}
        paidTotal={bill.paidTotal}
        refunded={bill.refunded}
        currency={r.currency}
        methods={methods ?? []}
        canPay={can(user, "order.create")}
        canVoid={can(user, "order.void")}
        canRefund={can(user, "order.refund")}
        shiftOpen={!!shift}
        cashRounding={bill.cashRoundingMode}
        splitPay={splitPay}
        lines={bill.lines}
        hasDiscount={bill.hasDiscount}
        hasPayments={r.payments.length > 0}
        tableId={bill.tableId}
        tables={(tables ?? []).map((t) => ({ id: t.id, number: t.table_number, busy: busyTables.has(t.id) }))}
        otherBills={(openBills ?? []).map((o) => ({
          id: o.id,
          billNumber: o.bill_number,
          total: Number(o.grand_total),
          table: o.dining_tables?.table_number ?? null,
          mergeable: o.payment_status === "unpaid" && Number(o.discount_total) === 0,
        }))}
      />
    </div>
  );
}
