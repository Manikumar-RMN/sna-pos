import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, haveDb, rpc, uuid } from "./support/db";
import { items, makeWorld, type World } from "./support/world";

const money = (x: unknown) => Math.round(Number(x) * 100);
const settle = <T>(ps: Promise<T>[]) => Promise.allSettled(ps);

describe.skipIf(!haveDb())("many tills at once: no duplicate bill numbers, no double payments, no lost items", () => {
  let w: World;
  const cashier = () => w.cashier.auth;
  beforeAll(async () => { w = await makeWorld("conc"); await rpc(cashier(), "open_shift", [0]); });
  afterAll(closePool);

  it("30 bills taken at the same moment all get different, gap-free bill numbers", async () => {
    const res = await settle(Array.from({ length: 30 }, () => rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 200])));
    expect(res.filter((r) => r.status === "rejected").map((r) => (r as PromiseRejectedResult).reason.message)).toEqual([]);
    const nums = res.map((r) => (r as PromiseFulfilledResult<any>).value.bill_number as string);
    expect(new Set(nums).size).toBe(30);
    const seq = nums.map((n) => Number(n.split("-").pop())).sort((a, b) => a - b);
    expect(seq[seq.length - 1] - seq[0]).toBe(29); // consecutive: no number skipped or reused
    const [{ n }] = await admin("select count(*)::int n from public.orders where restaurant_id = $1", [w.restaurantId]);
    expect(n).toBe(30);
  });

  it("the same bill tapped 10 times at once is one bill and one payment", async () => {
    const ref = uuid();
    const args = [items(w, { biryani: 1 }), "takeaway", null, null, w.methods.cash, 300, 0, null, null, null, null, ref];
    const res = await settle(Array.from({ length: 10 }, () => rpc(cashier(), "create_order", args)));
    const ok = res.filter((r) => r.status === "fulfilled").map((r) => (r as PromiseFulfilledResult<any>).value);
    expect(ok.length).toBeGreaterThanOrEqual(1);
    expect(new Set(ok.map((o) => o.order_id)).size).toBe(1);
    const [{ n }] = await admin("select count(*)::int n from public.orders where client_ref = $1", [ref]);
    const [{ p }] = await admin("select count(*)::int p from public.payments where order_id = $1", [ok[0].order_id]);
    expect([n, p]).toEqual([1, 1]);
  });

  it("two tills paying the same open bill in full at once: it is paid once, never twice", async () => {
    const u = await rpc(cashier(), "create_order", [items(w, { thali: 2 }), "dine_in", w.tableId]);
    const total = money(u.grand_total);
    const res = await settle(Array.from({ length: 6 }, () => rpc(cashier(), "pay_order", [u.order_id, w.methods.cash, 1000])));
    expect(res.filter((r) => r.status === "fulfilled").length).toBeGreaterThanOrEqual(1);
    const pays = await admin("select amount from public.payments where order_id = $1 and status = 'captured'", [u.order_id]);
    expect(pays.reduce((s, p) => s + money(p.amount), 0)).toBe(total);
  });

  it("two people adding items to one bill at once: every item is on it exactly once", async () => {
    const u = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "dine_in", w.tableId]);
    await settle(Array.from({ length: 8 }, () => rpc(cashier(), "add_order_items", [u.order_id, items(w, { cola: 1 }), uuid()])));
    const [{ q }] = await admin("select coalesce(sum(quantity),0)::int q from public.order_items where order_id = $1 and product_id = $2", [u.order_id, w.products.cola.id]);
    expect(q).toBe(8);
    const [row] = await admin("select grand_total from public.orders where id = $1", [u.order_id]);
    const quote = await rpc(w.manager.auth, "quote_order", [items(w, { dosa: 1, cola: 8 })]);
    expect(money(row.grand_total)).toBe(money(quote.grand_total));
  });

  it("two managers refunding the same bill at once can never refund more than was paid", async () => {
    const o = await rpc(cashier(), "create_order", [items(w, { biryani: 2 }), "takeaway", null, null, w.methods.cash, 1000]);
    const paid = money(o.grand_total);
    const res = await settle(Array.from({ length: 6 }, () => rpc(w.manager.auth, "issue_credit_note", [o.order_id, paid / 100 / 2 + 1, w.methods.cash, "race"])));
    const refunded = (await admin("select coalesce(sum(amount),0) s from public.refunds where order_id = $1", [o.order_id]))[0].s;
    expect(money(refunded)).toBeLessThanOrEqual(paid);
    expect(res.filter((r) => r.status === "fulfilled").length).toBe(1);
  });
});
