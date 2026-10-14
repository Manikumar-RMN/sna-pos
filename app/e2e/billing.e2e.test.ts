import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, asUser, closePool, haveDb, rpc, uuid } from "./support/db";
import { expectError, oracle } from "./support/oracle";
import { items, makeWorld, type World } from "./support/world";

const money = (x: unknown) => Math.round(Number(x) * 100);

describe.skipIf(!haveDb())("billing: totals, payments, edits, voids and refunds", () => {
  let w: World;
  const cashier = () => w.cashier.auth, manager = () => w.manager.auth;
  beforeAll(async () => {
    w = await makeWorld("bill");
    await rpc(cashier(), "open_shift", [1000]);
  });
  afterAll(closePool);

  const order = async (id: string) => (await admin("select * from public.orders where id = $1", [id]))[0];
  const payments = async (id: string) => admin("select * from public.payments where order_id = $1 order by created_at", [id]);

  describe("the database total equals the app's own calculator, to the paisa", () => {
    const carts: Record<string, Record<string, number>>[] = [
      { c: { dosa: 1 } }, { c: { dosa: 3 } }, { c: { biryani: 7 } }, { c: { cola: 3 } }, { c: { thali: 3 } },
      { c: { dosa: 2, cola: 1 } }, { c: { dosa: 1, biryani: 1, cola: 1, thali: 1 } }, { c: { thali: 1, cola: 9, biryani: 2 } },
    ];
    for (const { c } of carts)
      it(JSON.stringify(c), async () => {
        const expected = await oracle(w, c);
        const q = await rpc(manager(), "quote_order", [items(w, c)]);
        expect(money(q.grand_total)).toBe(money(expected.grand_total));
        expect(money(q.tax_total)).toBe(money(expected.tax_total));
        expect(money(q.subtotal)).toBe(money(expected.subtotal));
        // and the bill that is saved says the same as the quote
        const o = await rpc(cashier(), "create_order", [items(w, c), "takeaway"]);
        expect(money(o.grand_total)).toBe(money(expected.grand_total));
        expect(money((await order(o.order_id)).grand_total)).toBe(money(expected.grand_total));
      });

    it("with a discount (manager) and with a service charge", async () => {
      await admin("update public.branch_settings set service_charge_percent = 10 where branch_id = $1", [w.branchId]);
      const c = { biryani: 3, cola: 2 };
      const eDisc = await oracle(w, c, { discount: 77.5 });
      const qd = await rpc(manager(), "quote_order", [items(w, c), 77.5]);
      expect(money(qd.grand_total)).toBe(money(eDisc.grand_total));
      expect(money(qd.discount)).toBe(money(eDisc.discount));
      const eSc = await oracle(w, c, { serviceCharge: { percent: 10, taxable: false } });
      const qs = await rpc(manager(), "quote_order", [items(w, c), 0, true]);
      expect(money(qs.grand_total)).toBe(money(eSc.grand_total));
      expect(money(qs.service_charge)).toBe(money(eSc.service_charge));
      await admin("update public.branch_settings set service_charge_percent = 0 where branch_id = $1", [w.branchId]);
    });
  });

  it("the customer's browser cannot choose the price: a 'price' sent with an item is ignored", async () => {
    const honest = await rpc(cashier(), "quote_order", [items(w, { dosa: 2 })]);
    const cheat = await rpc(cashier(), "quote_order", [[{ product_id: w.products.dosa.id, qty: 2, price: 1, unit_price: 1 }]]);
    expect(cheat.grand_total).toBe(honest.grand_total);
  });

  it("rejects empty bills, zero, negative and absurd quantities", async () => {
    await expectError(rpc(cashier(), "create_order", [[], "takeaway"]), /./);
    for (const qty of [0, -1, 100000]) await expectError(rpc(cashier(), "create_order", [[{ product_id: w.products.dosa.id, qty }], "takeaway"]), /./);
  });

  describe("paying", () => {
    it("cash with change: 262.00 bill, 500 tendered -> 238.00 back", async () => {
      const o = await rpc(cashier(), "create_order", [items(w, { biryani: 1 }), "takeaway", null, null, w.methods.cash, 500]);
      expect(o.paid).toBe(true);
      expect(money(o.grand_total)).toBe(26200);
      expect(money(o.change)).toBe(23800);
      const row = await order(o.order_id);
      expect([row.status, row.payment_status, money(row.paid_total)]).toEqual(["completed", "paid", 26200]);
      const p = await payments(o.order_id);
      expect(p).toHaveLength(1);
      expect(money(p[0].amount)).toBe(26200);
    });

    it("cash tendered below the bill is refused and nothing is recorded", async () => {
      const before = Number((await admin("select count(*) n from public.orders where restaurant_id = $1", [w.restaurantId]))[0].n);
      await expectError(rpc(cashier(), "create_order", [items(w, { biryani: 1 }), "takeaway", null, null, w.methods.cash, 100]), /./);
      expect(Number((await admin("select count(*) n from public.orders where restaurant_id = $1", [w.restaurantId]))[0].n)).toBe(before);
    });

    it("UPI keeps its reference; part payments add up and the bill closes only when paid in full", async () => {
      const u = await rpc(cashier(), "create_order", [items(w, { thali: 2 }), "dine_in", w.tableId]);
      const total = money(u.grand_total);
      const p1 = await rpc(cashier(), "pay_order", [u.order_id, w.methods.cash, 400, 400]);
      expect(p1.paid).toBe(false);
      expect(money(p1.balance)).toBe(total - 40000);
      expect((await order(u.order_id)).payment_status).toBe("partial");
      const p2 = await rpc(cashier(), "pay_order", [u.order_id, w.methods.upi, null, null, "UPI-REF-9"]);
      expect(p2.paid).toBe(true);
      const row = await order(u.order_id);
      expect([row.status, row.payment_status, money(row.paid_total)]).toEqual(["completed", "paid", total]);
      const pays = await payments(u.order_id);
      expect(pays.map((p) => money(p.amount))).toEqual([40000, total - 40000]);
      expect(pays[1].reference_no).toBe("UPI-REF-9");
    });

    it("a paid bill cannot be paid again", async () => {
      const o = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 200]);
      await expectError(rpc(cashier(), "pay_order", [o.order_id, w.methods.cash, 200]), /./);
      expect(await payments(o.order_id)).toHaveLength(1);
    });

    it("paying more than the balance never records more than is owed", async () => {
      const u = await rpc(cashier(), "create_order", [items(w, { thali: 1 }), "dine_in", w.tableId]);
      try { await rpc(cashier(), "pay_order", [u.order_id, w.methods.upi, null, 100000, "X"]); } catch { /* refusing is fine too */ }
      const sum = (await payments(u.order_id)).reduce((s, p) => s + money(p.amount), 0);
      expect(sum).toBeLessThanOrEqual(money(u.grand_total));
    });

    it("double tap: the same client_ref gives the same bill, one bill number, one payment", async () => {
      const ref = uuid();
      const args = [items(w, { dosa: 2 }), "takeaway", null, null, w.methods.cash, 300, 0, null, null, null, null, ref];
      const first = await rpc(cashier(), "create_order", args);
      const again = await rpc(cashier(), "create_order", args);
      expect(again.order_id).toBe(first.order_id);
      expect(again.bill_number).toBe(first.bill_number);
      expect(await payments(first.order_id)).toHaveLength(1);
      expect(Number((await admin("select count(*) n from public.orders where client_ref = $1", [ref]))[0].n)).toBe(1);
    });

    it("the same payment retried (same client_ref) is recorded once", async () => {
      const u = await rpc(cashier(), "create_order", [items(w, { thali: 1 }), "dine_in", w.tableId]);
      const ref = uuid();
      await rpc(cashier(), "pay_order", [u.order_id, w.methods.cash, 100, 100, null, ref]);
      const r = await rpc(cashier(), "pay_order", [u.order_id, w.methods.cash, 100, 100, null, ref]);
      expect(r.repeat).toBe(true);
      expect(await payments(u.order_id)).toHaveLength(1);
    });
  });

  describe("editing an open bill", () => {
    it("adding items recalculates the whole bill", async () => {
      const u = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "dine_in", w.tableId]);
      await rpc(cashier(), "add_order_items", [u.order_id, items(w, { cola: 2, thali: 1 })]);
      const expected = await oracle(w, { dosa: 1, cola: 2, thali: 1 });
      expect(money((await order(u.order_id)).grand_total)).toBe(money(expected.grand_total));
    });

    it("cancelling part of a line (manager, with a reason) recalculates; a cashier cannot", async () => {
      const u = await rpc(cashier(), "create_order", [items(w, { dosa: 3 }), "dine_in", w.tableId]);
      const [line] = await admin("select id from public.order_items where order_id = $1", [u.order_id]);
      await expectError(rpc(cashier(), "cancel_order_item", [line.id, 1, "oops"]), /does not allow|manager/i);
      await rpc(manager(), "cancel_order_item", [line.id, 1, "customer changed mind"]);
      const expected = await oracle(w, { dosa: 2 });
      expect(money((await order(u.order_id)).grand_total)).toBe(money(expected.grand_total));
    });

    it("an adjust/discount needs a manager, and cannot exceed the bill", async () => {
      const u = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway"]);
      await expectError(rpc(cashier(), "adjust_order", [u.order_id, 10, "regular"]), /manager|allow/i);
      await expectError(rpc(manager(), "adjust_order", [u.order_id, 10000, "too much"]), /./);
      await rpc(manager(), "adjust_order", [u.order_id, 20, "regular guest"]);
      const expected = await oracle(w, { dosa: 1 }, { discount: 20 });
      expect(money((await order(u.order_id)).grand_total)).toBe(money(expected.grand_total));
    });

    it("splitting a bill: each part is a proper bill and no item is lost or doubled", async () => {
      const u = await rpc(cashier(), "create_order", [items(w, { dosa: 2, cola: 1 }), "dine_in", w.tableId]);
      const lines = await admin("select id, product_id, quantity from public.order_items where order_id = $1 order by created_at", [u.order_id]);
      const cola = lines.find((l) => l.product_id === w.products.cola.id)!;
      const s = await rpc(cashier(), "split_order", [u.order_id, [{ order_item_id: cola.id, qty: 1 }]]);
      const a = await order(u.order_id), b = await order(s.order_id);
      expect(money(a.grand_total)).toBe(money((await oracle(w, { dosa: 2 })).grand_total));
      expect(money(b.grand_total)).toBe(money((await oracle(w, { cola: 1 })).grand_total));
      expect(a.bill_number).not.toBe(b.bill_number);
      const qty = Number((await admin("select sum(quantity - coalesce(cancelled_qty,0)) q from public.order_items where order_id in ($1,$2)", [u.order_id, s.order_id]))[0].q);
      expect(qty).toBe(3);
    });

    it("merging two open bills: the result is the combined bill and the other is closed out", async () => {
      await admin("update public.restaurants set edition = 'professional' where id = $1", [w.restaurantId]); // merging is a Professional feature
      const a = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "dine_in", w.tableId]);
      const b = await rpc(cashier(), "create_order", [items(w, { biryani: 1, cola: 1 }), "dine_in", w.tableId]);
      await rpc(manager(), "merge_orders", [a.order_id, b.order_id]);
      const expected = await oracle(w, { dosa: 1, biryani: 1, cola: 1 });
      expect(money((await order(a.order_id)).grand_total)).toBe(money(expected.grand_total));
      expect((await order(b.order_id)).merged_into).toBe(a.order_id);
      await expectError(rpc(cashier(), "pay_order", [b.order_id, w.methods.cash, 1000]), /./);
    });
  });

  describe("the menu the billing screen loads (v_menu, read by a signed-in cashier through the API)", () => {
    const menu = (who: string) => asUser(who, async (q) => (await q("select id, name, price, list_price, is_available from public.v_menu order by name")).rows);

    it("a signed-in cashier can read the menu with its prices", async () => {
      const rows = await menu(cashier());
      expect(rows.map((r) => r.name).sort()).toEqual(["Chicken Biryani", "Cola", "Masala Dosa", "Veg Thali"]);
      for (const r of rows) {
        const p = Object.values(w.products).find((x) => x.id === r.id)!;
        expect(money(r.price)).toBe(money(p.price));
        expect(money(r.list_price)).toBe(money(p.price));
      }
    });

    it("an outlet price replaces the menu price, and an active happy-hour rule lowers it; billing charges the same price the screen shows", async () => {
      await admin("insert into public.branch_prices (restaurant_id, branch_id, product_id, price) values ($1,$2,$3,140)", [w.restaurantId, w.branchId, w.products.dosa.id]);
      let dosa = (await menu(cashier())).find((r) => r.id === w.products.dosa.id)!;
      expect([money(dosa.price), money(dosa.list_price)]).toEqual([14000, 14000]);
      const ruleId = await rpc<string>(manager(), "save_price_rule", [{ name: "Half price dosa", kind: "percent_off", value: 50, days: [1, 2, 3, 4, 5, 6, 7], start_time: "00:00", end_time: "23:59", product_ids: [w.products.dosa.id], category_ids: [] }]);
      dosa = (await menu(cashier())).find((r) => r.id === w.products.dosa.id)!;
      expect([money(dosa.price), money(dosa.list_price)], "menu shows the offer price; list price is unchanged").toEqual([7000, 14000]);
      const others = (await menu(cashier())).filter((r) => r.id !== w.products.dosa.id);
      expect(others.every((r) => money(r.price) === money(r.list_price))).toBe(true);
      const q = await rpc(cashier(), "quote_order", [items(w, { dosa: 1 })]);
      expect(money(q.subtotal), "the bill uses the price on the screen").toBe(7000);
      await admin("delete from public.price_rules where id = $1", [ruleId]);
      await admin("delete from public.branch_prices where product_id = $1", [w.products.dosa.id]);
    });
  });

  describe("voids, credit notes and immutability", () => {
    it("a completed bill can be voided once, by a manager, with a reason; its payments are marked refunded", async () => {
      const o = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 200]);
      await expectError(rpc(manager(), "void_order", [o.order_id, ""]), /reason/i);
      await rpc(manager(), "void_order", [o.order_id, "wrong order"]);
      const row = await order(o.order_id);
      expect(row.status).toBe("voided");
      expect((await payments(o.order_id)).every((p) => p.status === "refunded")).toBe(true);
      await expectError(rpc(manager(), "void_order", [o.order_id, "again"]), /already voided/i);
      await expectError(rpc(cashier(), "pay_order", [o.order_id, w.methods.cash, 200]), /./);
    });

    it("credit notes: partial, then the rest, then no more; numbered, and tax is reversed in proportion", async () => {
      const o = await rpc(cashier(), "create_order", [items(w, { biryani: 2 }), "takeaway", null, null, w.methods.cash, 1000]);
      const total = money(o.grand_total);
      const c1 = await rpc(manager(), "issue_credit_note", [o.order_id, 100, w.methods.cash, "cold food"]);
      expect(c1.number).toMatch(/^CN-MN-/);
      expect(money(c1.remaining)).toBe(total - 10000);
      expect(money(c1.tax)).toBe(Math.round((10000 / total) * money((await admin("select sum(tax_amount) t from public.order_item_taxes where order_id = $1", [o.order_id]))[0].t)));
      const c2 = await rpc(manager(), "issue_credit_note", [o.order_id, Number(c1.remaining), w.methods.cash, "rest"]);
      expect(c2.number).not.toBe(c1.number);
      await expectError(rpc(manager(), "issue_credit_note", [o.order_id, 1, w.methods.cash, "one more"]), /already been fully refunded|most that can/i);
      await expectError(rpc(manager(), "void_order", [o.order_id, "too late"]), /./);
      expect((await order(o.order_id)).payment_status).toBe("refunded");
    });

    it("a credit note can never exceed what was paid, and a cashier cannot issue one", async () => {
      const o = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 200]);
      await expectError(rpc(manager(), "issue_credit_note", [o.order_id, 99999, w.methods.cash, "too much"]), /most that can be refunded/i);
      await expectError(rpc(cashier(), "issue_credit_note", [o.order_id, 10, w.methods.cash, "x"]), /does not allow/i);
    });

    it("a completed bill cannot be edited even by the database owner, only by the controlled functions", async () => {
      const o = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 200]);
      await expectError(admin("update public.orders set grand_total = 1 where id = $1", [o.order_id]), /./);
      await expectError(admin("delete from public.orders where id = $1", [o.order_id]), /./);
      await expectError(admin("delete from public.payments where order_id = $1", [o.order_id]), /./);
      await expectError(admin("update public.credit_notes set amount = 1"), /./);
      expect(money((await order(o.order_id)).grand_total)).toBe(money(o.grand_total));
    });

    it("every void, credit note and discount leaves an audit record naming the bill", async () => {
      const o = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 200]);
      const o2 = await rpc(cashier(), "create_order", [items(w, { biryani: 1 }), "takeaway", null, null, w.methods.cash, 300]);
      const d = await rpc(cashier(), "create_order", [items(w, { dosa: 1 }), "takeaway"]);
      await rpc(manager(), "void_order", [o.order_id, "audit check"]);
      await rpc(manager(), "issue_credit_note", [o2.order_id, 50, w.methods.cash, "audit check"]);
      await rpc(manager(), "adjust_order", [d.order_id, 15, "audit check"]);
      for (const [action, id, bill] of [["order.void", o.order_id, o.bill_number], ["credit_note.issue", o2.order_id, o2.bill_number], ["order.adjust", d.order_id, d.bill_number]] as const) {
        const rows = await admin("select user_id from public.audit_logs where restaurant_id = $1 and action = $2 and (entity_id = $3 or new_value::text like '%' || $4 || '%') and user_id = $5", [w.restaurantId, action, id, bill, w.manager.userId]);
        expect(rows.length, action).toBeGreaterThanOrEqual(1);
      }
    });
  });
});
