import { notFound } from "next/navigation";
import { can, requireUser } from "@/lib/auth";
import { getBill } from "@/lib/bill";
import { createClient } from "@/lib/supabase/server";
import { dateTime, money } from "@/lib/format";
import { ReceiptView } from "../pos/receipt-view";
import { BillActions } from "./bill-actions";

/** One bill: printable receipt, its history, and the actions the user may take. */
export async function BillScreen({ orderId, from }: { orderId: string; from: "pos" | "bills" }) {
  const user = await requireUser();
  const bill = await getBill(orderId);
  if (!bill) notFound();

  const supabase = await createClient();
  const [{ data: methods }, { data: shift }] = await Promise.all([
    supabase
      .from("payment_methods")
      .select("id, name, kind")
      .eq("is_active", true)
      .order("display_order"),
    supabase.from("shifts").select("id").eq("status", "open").limit(1).maybeSingle(),
  ]);

  const r = bill.receipt;
  const tz = r.timezone;

  return (
    <div>
      <ReceiptView
        data={r}
        backHref={from === "pos" ? "/pos" : "/bills"}
        backLabel={from === "pos" ? "New bill" : "All bills"}
        showNextBill={from === "pos" && r.state !== "unpaid"}
      />

      {(bill.refunds.length > 0 || bill.voidedAt) && (
        <div className="no-print card mx-auto mt-4 max-w-sm p-4 text-sm">
          <h2 className="mb-2 font-bold">History</h2>
          <ul className="space-y-1.5" style={{ color: "var(--color-ink-2)" }}>
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
        state={r.state}
        grandTotal={r.grandTotal}
        paidTotal={bill.paidTotal}
        refunded={bill.refunded}
        currency={r.currency}
        methods={methods ?? []}
        canPay={can(user, "order.create")}
        canVoid={can(user, "order.void")}
        canRefund={can(user, "order.refund")}
        shiftOpen={!!shift}
      />
    </div>
  );
}
