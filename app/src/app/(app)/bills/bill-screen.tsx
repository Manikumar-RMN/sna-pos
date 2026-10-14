import Link from "next/link";
import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { getBill } from "@/lib/bill";
import { createClient } from "@/lib/supabase/server";
import { dateTime, money } from "@/lib/format";
import { ReceiptView } from "../pos/receipt-view";
import { BillActions } from "./bill-actions";
import { WhatsAppShare } from "./whatsapp-share";
import { LoyaltyPanel } from "./loyalty-panel";
import { GuestDetails } from "./guest-details";
import { AccountPanel } from "./account-panel";
import { byTableNumber } from "@/lib/table-order";
import { describeOfflineFlags } from "@/lib/offline-flags";

/** One bill: printable receipt, its history, and the actions the user may take. */
export async function BillScreen({ orderId, from, splitPay = false }: { orderId: string; from: "pos" | "bills"; splitPay?: boolean }) {
  const user = await requireUser();
  const bill = await getBill(orderId);
  if (!bill) notFound();

  const r = bill.receipt;
  const tz = r.timezone;
  const open = r.state === "unpaid" || r.state === "part-paid";

  const supabase = await createClient();
  // Loyalty: the guest on this bill and their points.
  let guest: { name: string; phone: string; points: number } | null = null;
  if (has(user, "loyalty")) {
    const { data: o } = await supabase.from("orders").select("customer_id, customers!orders_customer_id_fkey(name, phone)").eq("id", bill.id).maybeSingle();
    const c = o?.customers as unknown as { name: string; phone: string } | null;
    if (o?.customer_id && c) {
      const { data: led } = await supabase.from("loyalty_ledger").select("points").eq("customer_id", o.customer_id);
      guest = { name: c.name, phone: c.phone, points: (led ?? []).reduce((t, x) => t + Number(x.points), 0) };
    }
  }
  const [{ data: methods }, { data: shift }, { data: tables }, { data: openBills }, { data: mergedTo }] = await Promise.all([
    supabase.from("payment_methods").select("id, name, kind, ask_reference, upi_id").eq("is_active", true).not("kind", "in", "(gift_card,loyalty)").order("display_order"),
    supabase.from("shifts").select("id").eq("status", "open").limit(1).maybeSingle(),
    open
      ? supabase.from("dining_tables").select("id, table_number").eq("is_active", true).eq("is_kiosk", false).order("table_number")
      : Promise.resolve({ data: [] as { id: string; table_number: string }[] }),
    open
      ? supabase
          .from("orders")
          .select("id, bill_number, grand_total, dining_table_id, payment_status, discount_total, dining_tables!orders_dining_table_id_fkey(table_number)")
          .in("payment_status", ["unpaid", "partial"])
          .neq("status", "voided")
          .neq("id", bill.id)
          .order("created_at")
      : Promise.resolve({ data: [] as never[] }),
    bill.mergedInto
      ? supabase.from("orders").select("id, bill_number").eq("id", bill.mergedInto).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  // Bills made offline: what the server noted when it checked them (managers only).
  let offlineNotes: string[] = [];
  if (can(user, "order.void")) {
    const { data: fl } = await supabase.from("orders").select("offline_flags").eq("id", bill.id).maybeSingle();
    offlineNotes = describeOfflineFlags(fl?.offline_flags);
  }

  // Customer accounts (pay later), for "Charge to account" on an unpaid bill.
  const { data: accounts } = open && can(user, "payment.take") ? await supabase.rpc("accounts_list") : { data: null };

  const busyTables = new Set((openBills ?? []).map((o) => o.dining_table_id).filter(Boolean));

  return (
    <div>
      {offlineNotes.length > 0 && (
        <div className="no-print card mx-auto mb-3 max-w-sm p-3 text-sm" role="alert" style={{ borderColor: "var(--color-bad)" }}>
          <b>This bill was made offline and needed a correction:</b>
          <ul className="mt-1 list-disc pl-5">
            {offlineNotes.map((t) => (
              <li key={t}>{t}</li>
            ))}
          </ul>
        </div>
      )}
      {mergedTo && (
        <div className="no-print card mx-auto mb-3 max-w-sm p-3 text-sm">
          This bill was merged into{" "}
          <Link href={`/bills/${mergedTo.id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
            bill {mergedTo.bill_number}
          </Link>
          .
        </div>
      )}

      <GuestDetails
        orderId={bill.id}
        token={r.token ?? null}
        guest={r.guest ?? null}
        delivery={r.orderType === "delivery"}
        canEdit={r.state !== "voided" && !bill.dayClosed && can(user, "order.create")}
      />

      <ReceiptView
        data={r}
        backHref={from === "pos" ? "/pos" : "/bills"}
        backLabel={from === "pos" ? "New bill" : "All bills"}
        showNextBill={from === "pos" && !open}
      />

      {(bill.refunds.length > 0 || bill.voidedAt || bill.cancelled.length > 0 || bill.creditNotes.length > 0) && (
        <div className="no-print card mx-auto mt-4 max-w-sm p-4 text-sm">
          <h2 className="mb-2 font-bold">History</h2>
          <ul className="space-y-1.5" style={{ color: "var(--color-ink-2)" }}>
            {bill.cancelled.map((c, i) => (
              <li key={`c${i}`}>
                Cancelled {c.qty} × {c.name}
                {c.reason ? ` — ${c.reason}` : ""}
              </li>
            ))}
            {bill.creditNotes.map((cn) => (
              <li key={cn.id}>
                <Link href={`/bills/credit-note/${cn.id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                  Credit note {cn.number}
                </Link>{" "}
                {money(cn.amount, r.currency)}, {dateTime(cn.at, tz)} — {cn.reason}
              </li>
            ))}
            {bill.refunds
              .filter((f) => !bill.creditNotes.some((cn) => cn.reason === f.reason && cn.amount === f.amount))
              .map((f, i) => (
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

      {has(user, "loyalty") && r.state !== "voided" && (
        <LoyaltyPanel orderId={bill.id} open={open} canPay={can(user, "payment.take")} currency={r.currency} guest={guest} />
      )}

      {open && accounts && (
        <AccountPanel
          orderId={bill.id}
          currency={r.currency}
          accounts={accounts as unknown as { id: string; name: string; phone: string | null; company: string | null; limit: number | null; balance: number }[]}
        />
      )}

      {has(user, "whatsapp") && r.state !== "voided" && (
        <WhatsAppShare
          orderId={bill.id}
          country={user.country_code}
          text={`${user.trading_name} — bill ${r.billNumber}, total ${money(r.grandTotal, r.currency)}.`}
        />
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
        canPay={can(user, "payment.take")}
        canVoid={can(user, "order.void")}
        canMerge={has(user, "merge")}
        canDiscount={can(user, "order.discount")}
        adjust={bill.adjust}
        canChangeMode={can(user, "payment.change_mode")}
        dayClosed={bill.dayClosed}
        heldCount={bill.heldCount}
        buyer={user.country_code === "IN" ? (r.buyer ?? null) : undefined}
        taxIdLabel={r.taxIdLabel}
        paymentList={bill.paymentList}
        upiPayee={r.upi?.payee ?? null}
        canRefund={can(user, "order.refund")}
        shiftOpen={!!shift}
        cashRounding={bill.cashRoundingMode}
        splitPay={splitPay}
        lines={bill.lines}
        hasDiscount={bill.hasDiscount}
        hasPayments={r.payments.length > 0}
        tableId={bill.tableId}
        tables={[...(tables ?? [])].sort(byTableNumber).map((t) => ({ id: t.id, number: t.table_number, busy: busyTables.has(t.id) }))}
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
