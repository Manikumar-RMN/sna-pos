import Link from "next/link";
import { notFound } from "next/navigation";
import { can, has, requireUser } from "@/lib/auth";
import { getBill } from "@/lib/bill";
import { createClient } from "@/lib/supabase/server";
import { dateTime, money } from "@/lib/format";
import { ReceiptView, type ReceiptData } from "../pos/receipt-view";
import { BillActions } from "./bill-actions";
import { WhatsAppShare } from "./whatsapp-share";
import { LoyaltyPanel, type RedeemSettings } from "./loyalty-panel";
import { discountPool, receiptLoyalty } from "./loyalty-math";
import { GuestDetails } from "./guest-details";
import { AccountPanel } from "./account-panel";
import { byTableNumber } from "@/lib/table-order";
import { describeOfflineFlags } from "@/lib/offline-flags";

/**
 * One bill: printable receipt, its history, and the actions the user may take.
 * `embedded` = shown as the right-hand panel of the single order screen (/pos?bill=...): no "back" link of its own, and the
 * links and follow-up pages it would open (split, merged bill, add items) stay on that screen.
 */
export async function BillScreen({
  orderId,
  from,
  splitPay = false,
  embedded = false,
}: {
  orderId: string;
  from: "pos" | "bills";
  splitPay?: boolean;
  embedded?: boolean;
}) {
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
  // Batch 3: lines that cannot take a discount (bill.lines[].blocked, from order_items.discount_blocked), the points discount already on this bill
  // (bill.adjust.loyaltyDiscount / loyaltyPoints, from orders.calc_params), the redeem rules and this bill's ledger rows for the receipt.
  const [setRes, ledgerRes] = await Promise.all([
    has(user, "loyalty")
      ? supabase.from("loyalty_settings").select("point_value, min_redeem, redeem_mode, max_redeem_percent").eq("restaurant_id", user.restaurant_id).maybeSingle()
      : Promise.resolve({ data: null }),
    has(user, "loyalty") ? supabase.from("loyalty_ledger").select("kind, points").eq("order_id", bill.id) : Promise.resolve({ data: null }),
  ]);
  const pool = discountPool(bill.lines.map((l) => ({ amount: l.amount, blocked: l.blocked })));
  const loyalApplied = { points: bill.adjust.loyaltyPoints, discount: bill.adjust.loyaltyDiscount };
  const sRow = setRes.data;
  const redeemSettings: RedeemSettings = {
    mode: sRow?.redeem_mode === "discount" ? "discount" : "tender",
    pointValue: Number(sRow?.point_value ?? 0),
    minRedeem: Number(sRow?.min_redeem ?? 0),
    maxPercent: Number(sRow?.max_redeem_percent ?? 100),
  };
  // Receipt: points earned, used and the balance (ReceiptData.loyalty).
  const receipt: ReceiptData = guest
    ? { ...r, loyalty: receiptLoyalty((ledgerRes.data ?? []) as { kind: string; points: number }[], guest.points) }
    : r;

  // Stage 3: item / category discount and "No Tax" (manager right, unpaid bill, no senior/PWD discount).
  let discTools:
    | { categories: { id: string; name: string }[]; itemDisc: Record<string, { kind: "percent" | "amount"; value: number }>; noTax: boolean; noTaxAllowed: boolean }
    | undefined;
  if (open && !bill.dayClosed && can(user, "order.discount") && !bill.adjust.senior && bill.paidTotal === 0) {
    const { data: its } = await supabase.from("order_items").select("id, product_id, disc_kind, disc_value").eq("order_id", bill.id).is("cancelled_at", null);
    const pids = [...new Set((its ?? []).map((x) => x.product_id).filter((x): x is string => !!x))];
    const { data: prods } = pids.length ? await supabase.from("products").select("id, category_id").in("id", pids) : { data: [] as { id: string; category_id: string | null }[] };
    const cids = [...new Set((prods ?? []).map((x) => x.category_id).filter((x): x is string => !!x))];
    const { data: cats } = cids.length ? await supabase.from("categories").select("id, name").in("id", cids) : { data: [] as { id: string; name: string }[] };
    const { data: ord } = await supabase.from("orders").select("branch_id, calc_params").eq("id", bill.id).maybeSingle();
    const { data: bset } = ord?.branch_id ? await supabase.from("branch_settings").select("allow_no_tax").eq("branch_id", ord.branch_id).maybeSingle() : { data: null };
    const itemDisc: Record<string, { kind: "percent" | "amount"; value: number }> = {};
    for (const x of its ?? []) if (x.disc_kind && Number(x.disc_value) > 0) itemDisc[x.id] = { kind: x.disc_kind === "amount" ? "amount" : "percent", value: Number(x.disc_value) };
    const cp = (ord?.calc_params ?? {}) as { no_tax?: boolean };
    discTools = { categories: cats ?? [], itemDisc, noTax: !!cp.no_tax, noTaxAllowed: !!bset?.allow_no_tax };
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
  // Saved discounts (Settings → Discounts) valid today for this outlet and kind of bill: shown as buttons in the Discount box.
  const { data: presetRows } = open ? await supabase.rpc("list_discount_presets", { p_order_type: r.orderType }) : { data: null };
  const { data: accounts } = open && can(user, "payment.take") ? await supabase.rpc("accounts_list") : { data: null };

  const busyTables = new Set((openBills ?? []).map((o) => o.dining_table_id).filter(Boolean));

  // Winsar "KOT Table Transfer other outlet": the outlets of this restaurant and their tables, for an unpaid bill.
  const canTransfer = open && !bill.dayClosed && can(user, "order.void") && bill.paidTotal === 0;
  const [{ data: outletRows }, { data: allTables }] = canTransfer
    ? await Promise.all([
        supabase.from("branches").select("id, name").eq("is_active", true).order("name"),
        supabase.from("dining_tables").select("id, table_number, branch_id").eq("is_active", true).eq("is_kiosk", false).order("table_number"),
      ])
    : [{ data: null }, { data: null }];
  const { data: ordRow } = await supabase.from("orders").select("branch_id, waiter_id, cashier_id").eq("id", bill.id).maybeSingle();
  const serverId = ordRow?.waiter_id ?? ordRow?.cashier_id ?? null;
  const { data: serverRow } = serverId ? await supabase.from("users").select("full_name").eq("id", serverId).maybeSingle() : { data: null };

  // Winsar shows each round under its real KOT number, user and time. kitchen_ticket_items ties an item to its ticket.
  // Looked up by item, not by bill: a bill split off from another keeps the original kitchen tickets of the items it took.
  const lineIds = bill.lines.map((l) => l.id);
  const { data: kotRows } = lineIds.length
    ? await supabase.from("kitchen_ticket_items").select("order_item_id, kitchen_tickets(ticket_number, created_at)").in("order_item_id", lineIds)
    : { data: [] };
  const lineKot: Record<string, { no: string; at: string }> = {};
  for (const it of (kotRows ?? []) as unknown as { order_item_id: string | null; kitchen_tickets: { ticket_number: string; created_at: string } | null }[]) {
    if (it.order_item_id && it.kitchen_tickets) lineKot[it.order_item_id] = { no: it.kitchen_tickets.ticket_number, at: it.kitchen_tickets.created_at };
  }

  return (
    <div className={embedded ? "flex flex-col gap-3" : undefined}>
      <div className={embedded ? "order-2" : undefined}>
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
          <Link href={embedded ? `/pos?bill=${mergedTo.id}` : `/bills/${mergedTo.id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
            bill {mergedTo.bill_number}
          </Link>
          .
        </div>
      )}

      {bill.flags.length > 0 && (
        <div className="no-print card mx-auto mb-3 max-w-sm p-3 text-sm" style={{ borderColor: "var(--color-warn, #b45309)" }}>
          <div className="font-semibold">Please check this bill</div>
          <ul className="mt-1 list-disc pl-5">
            {bill.flags.map((f) => (
              <li key={f}>{f}</li>
            ))}
          </ul>
        </div>
      )}

      <GuestDetails
        orderId={bill.id}
        token={r.token ?? null}
        guest={r.guest ?? null}
        delivery={r.orderType === "delivery"}
        showPoints={has(user, "loyalty")}
        canEdit={r.state !== "voided" && !bill.dayClosed && can(user, "order.create")}
      />

      <ReceiptView
        data={receipt}
        backHref={from === "pos" ? "/pos" : "/bills"}
        backLabel={from === "pos" ? "New bill" : "All bills"}
        showNextBill={from === "pos" && !open}
        orderId={bill.id}
        hideBack={embedded}
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
        <LoyaltyPanel
          orderId={bill.id}
          open={open}
          canPay={can(user, "payment.take")}
          currency={r.currency}
          guest={guest}
          settings={redeemSettings}
          applied={loyalApplied}
          pool={pool}
          manualDiscount={bill.adjust.discount}
          due={bill.balance}
          senior={bill.adjust.senior}
          hasPayments={r.payments.length > 0}
        />
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

      </div>

      <BillActions
        totals={{ subtotal: r.subtotal, discount: r.discount, tax: r.taxTotal }}
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
        canKots={open && !bill.dayClosed && can(user, "order.create")}
        adjust={bill.adjust}
        discountPool={pool}
        discTools={discTools}
        presets={(presetRows ?? []).map((x: { id: string; name: string; kind: string; value: number }) => ({ id: x.id, name: x.name, kind: x.kind === "amount" ? "amount" : "percent", value: Number(x.value) }))}
        loyaltyDiscount={loyalApplied.discount}
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
        embedded={embedded}
        lines={bill.lines}
        hasDiscount={bill.hasDiscount}
        hasPayments={r.payments.length > 0}
        tableId={bill.tableId}
        tables={[...(tables ?? [])].sort(byTableNumber).map((t) => ({ id: t.id, number: t.table_number, busy: busyTables.has(t.id) }))}
        compNow={r.comp?.kind ?? null}
        businessDate={bill.businessDate}
        branchId={ordRow?.branch_id ?? null}
        outlets={(outletRows ?? []).map((b) => ({ id: b.id, name: b.name }))}
        outletTables={(allTables ?? []).map((t) => ({ id: t.id, number: t.table_number, branchId: t.branch_id, busy: busyTables.has(t.id) }))}
        serverName={serverRow?.full_name ?? null}
        lineKot={lineKot}
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
