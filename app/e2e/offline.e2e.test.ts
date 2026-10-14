import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, haveDb, rpc, uuid } from "./support/db";
import { expectError, oracle } from "./support/oracle";
import { items, makeWorld, type World } from "./support/world";

const money = (x: unknown) => Math.round(Number(x) * 100);

describe.skipIf(!haveDb())("offline bills: accepted when honest, corrected and reported when not", () => {
  let w: World, device: string, snap: any, seq = 0;
  const cashier = () => w.cashier.auth;
  beforeAll(async () => {
    w = await makeWorld("off");
    await admin("insert into public.restaurant_modules (restaurant_id, module_key) values ($1, 'owner_app') on conflict do nothing", [w.restaurantId]);
    await rpc(cashier(), "open_shift", [0]);
    device = uuid();
    snap = await rpc(cashier(), "offline_snapshot", [device]);
  });
  afterAll(closePool);

  /** A bill exactly as the till stores it while the internet is down. */
  async function bill(cart: Record<string, number>, o: { price?: Record<string, number>; discount?: number; method?: string; number?: string; createdAt?: Date; snapshotAt?: string | null; claimTotal?: number } = {}) {
    seq += 1;
    const calc = await oracle(w, cart, { discount: o.discount ?? 0, prices: o.price });
    const menu = Object.fromEntries(snap.menu.map((m: any) => [m.id, m]));
    return {
      client_id: uuid(), device_key: device, seq, fy: snap.series.fy,
      number: o.number ?? `${snap.series.branch_code}-${snap.series.prefix}-${String(snap.series.next_seq + seq - 1).padStart(4, "0")}`,
      created_at: (o.createdAt ?? new Date()).toISOString(), order_type: "takeaway", guest: null,
      items: Object.entries(cart).map(([k, qty]) => ({ product_id: w.products[k].id, name: menu[w.products[k].id].name, qty, price: o.price?.[k] ?? menu[w.products[k].id].price, options: [], options_text: null, station: "Kitchen" })),
      discount: o.discount ?? 0, service_charge: false, method_id: o.method ?? w.methods.cash, method_name: "Cash",
      tendered: 2000, reference: null, grand_total: o.claimTotal ?? calc.grand_total, due: calc.grand_total, calc,
      ...(o.snapshotAt !== undefined ? { snapshot_at: o.snapshotAt } : { snapshot_at: snap.taken_at }),
    };
  }
  const sync = (b: unknown, who = cashier()) => rpc(who, "sync_offline_bill", [b]);
  const row = async (id: string) => (await admin("select * from public.orders where id = $1", [id]))[0];
  const flags = (r: any): any[] => r.offline_flags ?? [];

  it("an honest bill is recorded as it was made: same number, same total, paid, no flags", async () => {
    const b = await bill({ dosa: 2, cola: 1 });
    const r = await sync(b);
    expect(r.ok).toBe(true);
    const o = await row(r.order_id);
    expect(o.bill_number).toBe(b.number);
    expect(money(o.grand_total)).toBe(money(b.grand_total));
    expect([o.status, o.payment_status]).toEqual(["completed", "paid"]);
    expect(flags(o)).toEqual([]);
    const p = await admin("select amount from public.payments where order_id = $1", [r.order_id]);
    expect(p.map((x) => money(x.amount))).toEqual([money(b.grand_total)]);
  });

  it("sending the same bill again (lost reply, retry) never creates a second bill", async () => {
    const b = await bill({ biryani: 1 });
    const a = await sync(b), again = await sync(b);
    expect(again.order_id).toBe(a.order_id);
    expect(again.repeat).toBe(true);
    expect(Number((await admin("select count(*) n from public.orders where client_ref = $1", [b.client_id]))[0].n)).toBe(1);
  });

  it("a bill with a wrong or reused number is refused", async () => {
    await expectError(sync(await bill({ dosa: 1 }, { number: "MN26-X1-9999" })), /does not match this device/i);
    const first = await bill({ dosa: 1 });
    await sync(first);
    const clash = { ...(await bill({ dosa: 1 })), number: first.number, seq: first.seq };
    await expectError(sync(clash), /already used/i);
  });

  it("a bad quantity, an unknown item or another restaurant's device is refused", async () => {
    const q = await bill({ dosa: 1 }); q.items[0].qty = 0;
    await expectError(sync(q), /quantity/i);
    const gone = await bill({ dosa: 1 }); gone.items[0].product_id = uuid();
    await expectError(sync(gone), /no longer exists/i);
    const other = await makeWorld("offB");
    await expectError(sync(await bill({ dosa: 1 }), other.cashier.auth), /no offline bill series|does not match|./i);
  });

  it("a price that was never on the menu is NOT trusted: the bill is recorded at the real price, flagged, and the owner is told", async () => {
    const b = await bill({ dosa: 2 }, { price: { dosa: 1 } });          // the till says 1.00 instead of 120.00
    const r = await sync(b);
    const o = await row(r.order_id);
    const real = await oracle(w, { dosa: 2 });
    expect(money(o.grand_total), "recorded at the true price").toBe(money(real.grand_total));
    expect(flags(o).map((f) => f.flag)).toContain("price_corrected");
    const f = flags(o).find((x) => x.flag === "price_corrected");
    expect([f.offline_price, f.menu_price]).toEqual([1, 120]);
    const p = await admin("select amount from public.payments where order_id = $1", [r.order_id]);
    expect(p.reduce((s, x) => s + money(x.amount), 0), "the payment equals the bill, so the cash shortfall shows at shift close").toBe(money(real.grand_total));
    const alerts = await admin("select title, body from public.owner_alerts where restaurant_id = $1 and kind = 'order.offline_flagged'", [w.restaurantId]);
    expect(alerts.some((a) => a.body.includes(b.number))).toBe(true);
  });

  it("a price that WAS right when the till last updated its menu is accepted, even if the owner changed it since", async () => {
    const before = new Date().toISOString();
    await new Promise((r) => setTimeout(r, 30));
    await admin("update public.products set price = 130 where id = $1", [w.products.thali.id]); // owner raises the price while the till is offline
    const b = await bill({ thali: 1 }, { price: { thali: 333.33 }, snapshotAt: before });
    const r = await sync(b);
    const o = await row(r.order_id);
    expect(money(o.grand_total)).toBe(money(b.grand_total));
    expect(flags(o).map((f) => f.flag)).not.toContain("price_corrected");
    await admin("update public.products set price = 333.33 where id = $1", [w.products.thali.id]);
  });

  it("a discount by someone without the right is removed and reported; by a manager it is kept", async () => {
    const cheat = await bill({ biryani: 2 }, { discount: 100 });
    const rc = await sync(cheat);
    const oc = await row(rc.order_id);
    expect(money(oc.grand_total)).toBe(money((await oracle(w, { biryani: 2 })).grand_total));
    expect(flags(oc).map((f) => f.flag)).toContain("discount_removed");
    const okBill = await bill({ biryani: 2 }, { discount: 100 });
    const rm = await sync(okBill, w.manager.auth); // a manager has the right to discount
    const om = await row(rm.order_id);
    expect(money(om.grand_total)).toBe(money((await oracle(w, { biryani: 2 }, { discount: 100 })).grand_total));
    expect(flags(om).map((f) => f.flag)).not.toContain("discount_removed");
  });

  it("an unknown payment method is flagged, not silently turned into cash", async () => {
    const r = await sync(await bill({ dosa: 1 }, { method: uuid() }));
    expect(flags(await row(r.order_id)).map((f) => f.flag)).toContain("method_unknown");
  });

  it("a till clock running ahead is clamped to now and flagged", async () => {
    const r = await sync(await bill({ dosa: 1 }, { createdAt: new Date(Date.now() + 3 * 3600 * 1000) }));
    const o = await row(r.order_id);
    expect(new Date(o.created_at).getTime()).toBeLessThanOrEqual(Date.now() + 1000);
    expect(flags(o).map((f) => f.flag)).toContain("device_clock_ahead");
  });

  it("a total printed on the till that differs from the server's is flagged (the server's figure is the record)", async () => {
    const r = await sync(await bill({ dosa: 1 }, { claimTotal: 1 }));
    const o = await row(r.order_id);
    expect(flags(o).map((f) => f.flag)).toContain("total_differs");
    expect(money(o.grand_total)).toBe(money((await oracle(w, { dosa: 1 })).grand_total));
  });

  it("a business day is always the open one: an old till time cannot put a bill into a closed day", async () => {
    const r = await sync(await bill({ dosa: 1 }, { createdAt: new Date(Date.now() - 3 * 24 * 3600 * 1000) }));
    const o = await row(r.order_id);
    const [d] = await admin("select status from public.business_days where branch_id = $1 and business_date = $2", [w.branchId, o.business_date]);
    expect(d.status).toBe("open");
    expect(flags(o).map((f) => f.flag)).not.toContain("older_than_7_days"); // 3 days old is within the week
  });
});
