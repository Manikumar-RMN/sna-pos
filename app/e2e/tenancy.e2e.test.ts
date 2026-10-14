import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, asUser, closePool, haveDb, rpc, uuid } from "./support/db";
import { expectError } from "./support/oracle";
import { items, makeWorld, type World } from "./support/world";

describe.skipIf(!haveDb())("one restaurant can never see or touch another's data", () => {
  let a: World, b: World, billA: { order_id: string; bill_number: string };
  beforeAll(async () => {
    a = await makeWorld("tenA");
    b = await makeWorld("tenB");
    await rpc(a.cashier.auth, "open_shift", [0]);
    billA = await rpc(a.cashier.auth, "create_order", [items(a, { dosa: 2 }), "takeaway", null, null, a.methods.cash, 500]);
  });
  afterAll(closePool);

  it("B's owner sees none of A's bills, menu or staff", async () => {
    await asUser(b.owner.auth, async (q) => {
      expect((await q("select count(*)::int n from public.orders where restaurant_id = $1", [a.restaurantId])).rows[0].n).toBe(0);
      expect((await q("select count(*)::int n from public.products where restaurant_id = $1", [a.restaurantId])).rows[0].n).toBe(0);
      expect((await q("select count(*)::int n from public.users where restaurant_id = $1", [a.restaurantId])).rows[0].n).toBe(0);
      expect((await q("select count(*)::int n from public.payments p join public.orders o on o.id = p.order_id where o.restaurant_id = $1", [a.restaurantId])).rows[0].n).toBe(0);
      // and sees its own
      expect((await q("select count(*)::int n from public.products")).rows[0].n).toBe(4);
    });
  });

  it("B cannot void, refund, pay, split or merge A's bill, even knowing its id", async () => {
    const id = billA.order_id;
    await expectError(rpc(b.owner.auth, "void_order", [id, "attack"]), /not found/i);
    await expectError(rpc(b.owner.auth, "issue_credit_note", [id, 10, b.methods.cash, "attack"]), /not found/i);
    await expectError(rpc(b.owner.auth, "pay_order", [id, b.methods.cash, 1]), /not found/i);
    await expectError(rpc(b.owner.auth, "split_order", [id, [{ order_item_id: uuid(), qty: 1 }]]), /./);
    await expectError(rpc(b.owner.auth, "merge_orders", [id, id]), /./);
    const [row] = await admin("select status, paid_total from public.orders where id = $1", [id]);
    expect(row.status).toBe("completed");
  });

  it("B cannot bill A's products", async () => {
    await expectError(rpc(b.cashier.auth, "create_order", [items(a, { dosa: 1 }), "takeaway"]), /./);
  });

  it("nobody can write to bills, payments, credit notes, roles or the audit log directly", async () => {
    for (const who of [a.owner, a.manager, a.cashier]) {
      for (const sql of [
        "update public.orders set grand_total = 1",
        "delete from public.orders",
        "update public.payments set amount = 1",
        "delete from public.payments",
        "insert into public.payments (restaurant_id, order_id, payment_method_id, amount, currency_code) select restaurant_id, id, null, 1, 'INR' from public.orders limit 1",
        "update public.credit_notes set amount = 1",
        "delete from public.audit_logs",
        "update public.audit_logs set action = 'x'",
        "update public.role_permissions set permission_key = permission_key",
        "insert into public.role_permissions (role_id, permission_key) select id, 'order.void' from public.roles limit 1",
        "update public.restaurants set trading_name = 'hacked'",
        "truncate public.orders",
      ])
        await expectError(asUser(who.auth, (q) => q(sql)), /permission denied|row-level security/i);
    }
    const [row] = await admin("select grand_total from public.orders where id = $1", [billA.order_id]);
    expect(Number(row.grand_total)).toBeGreaterThan(1);
  });

  it("a signed-out visitor can do nothing with bills", async () => {
    const { getPool } = await import("./support/db");
    const c = await getPool().connect();
    try {
      await c.query("begin"); await c.query("set local role anon");
      await expectError(c.query("select * from public.orders"), /permission denied/i);
      await c.query("rollback"); await c.query("begin"); await c.query("set local role anon");
      await expectError(c.query("select public.create_order('[]'::jsonb)"), /permission denied/i);
    } finally { await c.query("rollback").catch(() => {}); c.release(); }
  });

  it("a cashier cannot do manager things", async () => {
    await expectError(rpc(a.cashier.auth, "void_order", [billA.order_id, "x"]), /does not allow/i);
    await expectError(rpc(a.cashier.auth, "issue_credit_note", [billA.order_id, 10, a.methods.cash, "x"]), /does not allow/i);
    await expectError(rpc(a.cashier.auth, "close_day", ["x"]), /does not allow/i);
    await expectError(rpc(a.cashier.auth, "create_order", [items(a, { dosa: 1 }), "takeaway", null, null, null, null, 10, "discount"]), /manager must approve/i);
  });
});
