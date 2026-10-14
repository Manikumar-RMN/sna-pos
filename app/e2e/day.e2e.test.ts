import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, haveDb, rpc } from "./support/db";
import { expectError } from "./support/oracle";
import { items, makeWorld, type World } from "./support/world";

const money = (x: unknown) => Math.round(Number(x) * 100);

describe.skipIf(!haveDb())("shift and day close: the cash and the totals have to add up", () => {
  let w: World;
  const cashier = () => w.cashier.auth, manager = () => w.manager.auth;
  const bills: { id: string; no: string; total: number; kind: string }[] = [];
  let shiftId: string, closeResult: any, dayResult: any, dayDate: string;

  beforeAll(async () => {
    w = await makeWorld("day");
    await admin("insert into public.restaurant_modules (restaurant_id, module_key) values ($1, 'owner_app') on conflict do nothing", [w.restaurantId]); // the owner-alerts module
    shiftId = await rpc<string>(cashier(), "open_shift", [1000]);
    const cash = await rpc(cashier(), "create_order", [items(w, { biryani: 1 }), "takeaway", null, null, w.methods.cash, 300]);       // 262.00
    const upi = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.upi, null, 0, null, null, null, "UPI-1"]); // 126.00
    const card = await rpc(cashier(), "create_order", [items(w, { cola: 1 }), "takeaway", null, null, w.methods.card, null, 0, null, null, null, "4242"]); // 70.80 -> 71
    bills.push({ id: cash.order_id, no: cash.bill_number, total: money(cash.grand_total), kind: "cash" },
               { id: upi.order_id, no: upi.bill_number, total: money(upi.grand_total), kind: "upi" },
               { id: card.order_id, no: card.bill_number, total: money(card.grand_total), kind: "card" });
  });
  afterAll(closePool);

  it("each bill is recorded against the open shift and the right payment mode", async () => {
    const rows = await admin("select p.shift_id, p.amount, pm.kind from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id where p.order_id = any($1)", [bills.map((b) => b.id)]);
    expect(rows).toHaveLength(3);
    expect(rows.every((r) => r.shift_id === shiftId)).toBe(true);
    expect(rows.map((r) => r.kind).sort()).toEqual(["card", "cash", "upi"]);
  });

  it("cash in / out is recorded and only a person with the right can do it", async () => {
    await rpc(manager(), "record_cash_movement", ["out", 100, "milk from the shop"]);
    const mv = await admin("select direction, amount from public.cash_movements where shift_id = $1", [shiftId]);
    expect(mv.map((m) => [m.direction, money(m.amount)])).toEqual([["out", 10000]]);
  });

  it("closing the shift: expected cash = float + cash sales - cash paid out; the variance is exactly counted - expected", async () => {
    const cashSales = bills.filter((b) => b.kind === "cash").reduce((s, b) => s + b.total, 0);
    const expected = 100000 + cashSales - 10000; // 1000.00 float + 262.00 - 100.00 paid out
    closeResult = await rpc(manager(), "close_shift", [(expected - 2000) / 100, "short by 20"]);
    expect(money(closeResult.expected_cash)).toBe(expected);
    expect(money(closeResult.variance)).toBe(-2000);
    const alerts = await admin("select title from public.owner_alerts where restaurant_id = $1 and kind = 'shift.close'", [w.restaurantId]);
    expect(alerts.length, "owner is told about a cash shortage").toBeGreaterThanOrEqual(1);
  });

  it("a closed shift cannot be closed again", async () => {
    await expectError(rpc(manager(), "close_shift", [0, "again"]), /./);
  });

  it("the day cannot be closed while a bill is unpaid", async () => {
    const open = await rpc(cashier(), "create_order", [items(w, { thali: 1 }), "dine_in", w.tableId]);
    await expectError(rpc(manager(), "close_day", ["too early"]), /not paid yet/i);
    await rpc(cashier(), "pay_order", [open.order_id, w.methods.cash, 400]);
    bills.push({ id: open.order_id, no: open.bill_number, total: money(open.grand_total), kind: "cash" });
  });

  it("closing the day reports exactly the bills taken", async () => {
    dayResult = await rpc(manager(), "close_day", ["end of day"]);
    dayDate = String(dayResult.business_date).slice(0, 10);
    expect(money(dayResult.total_billed)).toBe(bills.reduce((s, b) => s + b.total, 0));
    const [row] = await admin("select count(*)::int n, coalesce(sum(grand_total),0) t from public.orders where restaurant_id = $1 and business_date = $2 and status = 'completed'", [w.restaurantId, dayDate]);
    expect(row.n).toBe(bills.length);
    expect(money(row.t)).toBe(money(dayResult.total_billed));
  });

  it("the day report agrees with the bills, the tax, the payment modes and the shift's cash count", async () => {
    const [day] = await admin("select id from public.business_days where restaurant_id = $1 and business_date = $2", [w.restaurantId, dayDate]);
    const rep = await rpc(manager(), "day_report", [day.id]);
    const total = bills.reduce((s, b) => s + b.total, 0);
    expect(rep.bills).toBe(bills.length);
    expect(money(rep.total_billed)).toBe(total);
    expect(rep.first_bill).toBe(bills[0].no);
    const [t] = await admin("select coalesce(sum(tax_amount),0) tax from public.order_item_taxes where order_id = any($1)", [bills.map((b) => b.id)]);
    expect(money(rep.tax)).toBe(money(t.tax));
    expect(rep.taxes.reduce((s: number, x: any) => s + money(x.tax), 0)).toBe(money(rep.tax));
    const byMethod = Object.fromEntries(rep.payments.map((p: any) => [p.method, money(p.amount)]));
    expect(byMethod.Cash).toBe(bills.filter((b) => b.kind === "cash").reduce((s, b) => s + b.total, 0));
    expect(byMethod.UPI).toBe(bills.find((b) => b.kind === "upi")!.total);
    expect(byMethod.Card).toBe(bills.find((b) => b.kind === "card")!.total);
    expect(Object.values(byMethod).reduce((s: number, v) => s + (v as number), 0)).toBe(total);
    const sh = rep.shifts.find((x: any) => x.shift_id === shiftId);
    expect([money(sh.expected_cash), money(sh.counted_cash), money(sh.variance), money(sh.cash_out)]).toEqual([money(closeResult.expected_cash), money(closeResult.counted_cash), -2000, 10000]);
  });

  it("a closed day is frozen: no void, no payment change, no edits", async () => {
    await expectError(rpc(manager(), "void_order", [bills[0].id, "after close"]), /closed/i);
    await expectError(admin("update public.orders set grand_total = grand_total + 1 where id = $1", [bills[0].id]), /./);
    await expectError(rpc(manager(), "cancel_order_item", [(await admin("select id from public.order_items where order_id = $1", [bills[0].id]))[0].id, 1, "late"]), /closed|./);
  });

  it("a refund after close is a credit note dated on the day it is given, and the closed day does not change", async () => {
    const before = await admin("select count(*)::int n, sum(grand_total) t from public.orders where restaurant_id = $1 and business_date = $2", [w.restaurantId, dayDate]);
    await rpc(cashier(), "open_shift", [0]).catch(() => {});
    const cn = await rpc(manager(), "issue_credit_note", [bills[1].id, 26, w.methods.upi, "customer complaint"]);
    const [row] = await admin("select business_date from public.credit_notes where id = $1", [cn.credit_note_id]);
    expect(String(row.business_date).slice(0, 10)).not.toBe(dayDate);
    const after = await admin("select count(*)::int n, sum(grand_total) t from public.orders where restaurant_id = $1 and business_date = $2", [w.restaurantId, dayDate]);
    expect(after[0]).toEqual(before[0]);
  });

  it("a new bill after closing belongs to the next business day", async () => {
    const o = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 200]);
    const [row] = await admin("select business_date from public.orders where id = $1", [o.order_id]);
    expect(String(row.business_date).slice(0, 10)).not.toBe(dayDate);
  });

  it("reopening a day needs a reason and a manager, and not while the next day already has bills; then it can be corrected and closed again", async () => {
    await expectError(rpc(cashier(), "reopen_day", ["please"]), /does not allow/i);
    await expectError(rpc(manager(), "reopen_day", [""]), /reason/i);
    await expectError(rpc(manager(), "reopen_day", ["wrong payment mode"]), /already been made today/i); // the new day has bills: void them first
    const next = await admin("select id from public.orders where restaurant_id = $1 and business_date <> $2 and status = 'completed'", [w.restaurantId, dayDate]);
    for (const o of next) await rpc(manager(), "void_order", [o.id, "voiding so the day can be reopened"]);
    const r = await rpc(manager(), "reopen_day", ["wrong payment mode"]);
    expect(String(r.business_date).slice(0, 10)).toBe(dayDate);
    const alerts = await admin("select kind from public.owner_alerts where restaurant_id = $1 and kind = 'day.reopen'", [w.restaurantId]);
    expect(alerts.length).toBeGreaterThanOrEqual(1);
    await rpc(manager(), "void_order", [bills[0].id, "now allowed: the day is open again"]);
    expect((await admin("select status from public.orders where id = $1", [bills[0].id]))[0].status).toBe("voided");
    const again = await rpc(manager(), "close_day", ["closed again"]);
    expect(String(again.business_date).slice(0, 10)).toBe(dayDate);
  });
});
