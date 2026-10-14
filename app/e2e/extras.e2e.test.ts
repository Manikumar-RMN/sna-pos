import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, getPool, haveDb, rpc, uuid } from "./support/db";
import { expectError } from "./support/oracle";
import { items, makeWorld, type World } from "./support/world";

const cents = (x: unknown) => Math.round(Number(x) * 100);
const modules = (w: World, ...keys: string[]) => Promise.all(keys.map((k) => admin("insert into public.restaurant_modules (restaurant_id, module_key) values ($1, $2) on conflict do nothing", [w.restaurantId, k])));

/** A guest at the table: no login at all, so the database sees the `anon` role. */
async function asGuest<T = any>(fn: string, args: unknown[]): Promise<T> {
  const c = await getPool().connect();
  try {
    await c.query("begin");
    await c.query("set local role anon");
    await c.query("select set_config('request.jwt.claims', '{\"role\":\"anon\"}', true)");
    const ph = args.map((_, i) => `$${i + 1}`).join(", ");
    const r = await c.query(`select public.${fn}(${ph}) as v`, args.map((a) => (a !== null && typeof a === "object" ? JSON.stringify(a) : a)));
    await c.query("commit");
    return r.rows[0].v as T;
  } catch (e) {
    await c.query("rollback").catch(() => {});
    throw e;
  } finally {
    c.release();
  }
}

const drawerCash = async (shift: string) => {
  const [{ n }] = await admin("select coalesce(sum(case direction when 'in' then amount else -amount end),0) n from public.cash_movements where shift_id = $1", [shift]);
  return cents(n);
};

describe.skipIf(!haveDb())("loyalty and gift cards: money in, money out, and nothing lost", () => {
  let w: World, shift: string;
  beforeAll(async () => {
    w = await makeWorld("loy");
    await modules(w, "loyalty");
    shift = await rpc(w.cashier.auth, "open_shift", [0]);
  });
  afterAll(closePool);

  it("loyalty rules: only someone allowed to change settings can save them; zero spend per point is refused", async () => {
    await expectError(rpc(w.cashier.auth, "save_loyalty_settings", [100, 1, 0]), /allow|permission|right/i);
    await expectError(rpc(w.owner.auth, "save_loyalty_settings", [0, 1, 0]), /./);
    await expectError(rpc(w.owner.auth, "save_loyalty_settings", [100, -1, 0]), /./);
    await rpc(w.owner.auth, "save_loyalty_settings", [100, 1, 5]);
  });

  let card: { code: string };
  it("selling a gift card for cash puts the cash in the drawer; a UPI sale does not", async () => {
    card = await rpc(w.cashier.auth, "issue_gift_card", [1000, w.methods.cash, "9876543210", "Asha", 365]);
    expect(card.code).toMatch(/^GC[A-Z0-9]{8}$/);
    expect(await drawerCash(shift)).toBe(100000);
    await rpc(w.cashier.auth, "issue_gift_card", [500, w.methods.upi, null, null, 365]);
    expect(await drawerCash(shift)).toBe(100000);
    await expectError(rpc(w.cashier.auth, "issue_gift_card", [0, w.methods.cash, null, null, 365]), /value/i);
    await expectError(rpc(w.cashier.auth, "issue_gift_card", [-50, w.methods.cash, null, null, 365]), /value/i);
    await expectError(rpc(w.cashier.auth, "issue_gift_card", [50, uuid(), null, null, 365]), /how the guest paid/i);
  });

  it("looking a card up is case-insensitive and tells the balance and expiry", async () => {
    const c = await rpc(w.cashier.auth, "gift_card_lookup", [card.code.toLowerCase() + " "]);
    expect(cents(c.balance)).toBe(100000);
    expect(c.expired).toBe(false);
    await expectError(rpc(w.cashier.auth, "gift_card_lookup", ["NOPE"]), /No gift card/i);
  });

  it("a card can pay part of a bill; the rest is paid another way; the balance drops by what was used", async () => {
    const bill = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 2 }), "dine_in", w.tableId]);
    const total = cents(bill.grand_total);
    const r = await rpc(w.cashier.auth, "redeem_gift_card", [bill.order_id, card.code, 300]);
    expect(cents(r.used)).toBe(30000);
    expect(cents(r.card_balance)).toBe(70000);
    const cash = await rpc(w.cashier.auth, "pay_order", [bill.order_id, w.methods.cash, (total - 30000) / 100]);
    expect(cash.paid).toBe(true);
  });

  it("a card cannot pay more than its balance or more than the bill; an unknown code or other restaurant's card is refused", async () => {
    const bill = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 1 }), "dine_in", w.tableId]);
    const r = await rpc(w.cashier.auth, "redeem_gift_card", [bill.order_id, card.code, 99999]);
    expect(cents(r.used)).toBe(cents(bill.grand_total));
    const bill2 = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 1 }), "dine_in", w.tableId]);
    await expectError(rpc(w.cashier.auth, "redeem_gift_card", [bill2.order_id, "GCNOPE0000", null]), /No gift card/i);
    const other = await makeWorld("loyB");
    await modules(other, "loyalty");
    await rpc(other.cashier.auth, "open_shift", [0]);
    const foreign = await rpc(other.cashier.auth, "issue_gift_card", [100, other.methods.cash, null, null, 365]);
    await expectError(rpc(w.cashier.auth, "redeem_gift_card", [bill2.order_id, foreign.code, null]), /No gift card/i);
    await rpc(w.cashier.auth, "pay_order", [bill2.order_id, w.methods.cash, 500]);
  });

  it("two tills using the same card at the same moment cannot spend more than it holds", async () => {
    const c = await rpc(w.cashier.auth, "issue_gift_card", [100, w.methods.cash, null, null, 365]);
    const a = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 1 }), "takeaway"]);
    const b = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 1 }), "takeaway"]);
    const res = await Promise.allSettled([
      rpc(w.cashier.auth, "redeem_gift_card", [a.order_id, c.code, null]),
      rpc(w.manager.auth, "redeem_gift_card", [b.order_id, c.code, null]),
    ]);
    const bal = (await rpc(w.cashier.auth, "gift_card_lookup", [c.code])).balance;
    expect(Number(bal), "the card never goes below zero").toBeGreaterThanOrEqual(0);
    expect(res.filter((r) => r.status === "fulfilled").length).toBeGreaterThanOrEqual(1);
    for (const o of [a, b]) await rpc(w.cashier.auth, "pay_order", [o.order_id, w.methods.cash, 500]).catch(() => {});
  });

  it("topping a card up adds the money (cash goes in the drawer); paying a card back empties it and takes cash out", async () => {
    const c = await rpc(w.cashier.auth, "issue_gift_card", [200, w.methods.upi, null, null, 30]);
    const before = await drawerCash(shift);
    const t = await rpc(w.cashier.auth, "top_up_gift_card", [c.code, 300, w.methods.cash]);
    expect(cents(t.balance)).toBe(50000);
    expect(await drawerCash(shift)).toBe(before + 30000);
    await expectError(rpc(w.cashier.auth, "top_up_gift_card", [c.code, 0, w.methods.cash]), /amount/i);
    await expectError(rpc(w.cashier.auth, "pay_back_gift_card", [c.code]), /allow|permission|right/i);
    const p = await rpc(w.manager.auth, "pay_back_gift_card", [c.code]);
    expect(cents(p.paid_back)).toBe(50000);
    expect(await drawerCash(shift)).toBe(before + 30000 - 50000);
    await expectError(rpc(w.manager.auth, "pay_back_gift_card", [c.code]), /no balance/i);
    const h = await rpc(w.cashier.auth, "gift_card_history", [c.code]);
    expect(h.entries.map((e: any) => e.kind).sort()).toEqual(["issue", "payback", "topup"]);
    expect(Number(h.balance)).toBe(0);
  });

  it("an expired card cannot be used", async () => {
    const c = await rpc(w.cashier.auth, "issue_gift_card", [100, w.methods.cash, null, null, 30]);
    await admin("update public.gift_cards set expires_on = current_date - 1 where code = $1 and restaurant_id = $2", [c.code, w.restaurantId]);
    const bill = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 1 }), "takeaway"]);
    await expectError(rpc(w.cashier.auth, "redeem_gift_card", [bill.order_id, c.code, null]), /expired/i);
    await rpc(w.cashier.auth, "pay_order", [bill.order_id, w.methods.cash, 500]);
  });

  it("VOIDING a bill that was paid with a gift card gives the money back to the card", async () => {
    const c = await rpc(w.cashier.auth, "issue_gift_card", [500, w.methods.cash, null, null, 365]);
    const bill = await rpc(w.cashier.auth, "create_order", [items(w, { biryani: 1 }), "takeaway"]);
    await rpc(w.cashier.auth, "redeem_gift_card", [bill.order_id, c.code, null]);
    const mid = Number((await rpc(w.cashier.auth, "gift_card_lookup", [c.code])).balance);
    expect(mid).toBeLessThan(500);
    await rpc(w.manager.auth, "void_order", [bill.order_id, "wrong table"]);
    const after = Number((await rpc(w.cashier.auth, "gift_card_lookup", [c.code])).balance);
    expect(after, "a voided bill must not leave the guest's card short").toBe(500);
  });

  it("points: earned on a paid bill, used on another, and the guest cannot use more than they have", async () => {
    const b1 = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 3 }), "takeaway"]);
    await rpc(w.cashier.auth, "attach_customer", [b1.order_id, "9000000001", "Mani"]);
    await rpc(w.cashier.auth, "pay_order", [b1.order_id, w.methods.cash, 2000]);
    const [cust] = await admin("select id from public.customers where restaurant_id = $1 and phone like '%9000000001'", [w.restaurantId]);
    const earned = Number((await admin("select coalesce(sum(points),0) s from public.loyalty_ledger where customer_id = $1", [cust.id]))[0].s);
    expect(earned).toBe(Math.floor(cents(b1.grand_total) / 100 / 100));
    const b2 = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 1 }), "takeaway"]);
    await rpc(w.cashier.auth, "attach_customer", [b2.order_id, "9000000001", null]);
    await expectError(rpc(w.cashier.auth, "redeem_points", [b2.order_id, earned + 50]), /only .* points/i);
    await expectError(rpc(w.cashier.auth, "redeem_points", [b2.order_id, 1]), /At least/i);
    const r = await rpc(w.cashier.auth, "redeem_points", [b2.order_id, earned]);
    expect(Number(r.points_left)).toBe(0);
    await rpc(w.cashier.auth, "pay_order", [b2.order_id, w.methods.cash, 500]);
  });

  it("a credit note takes back the points that bill earned, and never more than were earned", async () => {
    const b = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 3 }), "takeaway"]);
    await rpc(w.cashier.auth, "attach_customer", [b.order_id, "9000000002", "Dev"]);
    await rpc(w.cashier.auth, "pay_order", [b.order_id, w.methods.cash, 2000]);
    const [cust] = await admin("select id from public.customers where restaurant_id = $1 and phone like '%9000000002'", [w.restaurantId]);
    const pts = async () => Number((await admin("select coalesce(sum(points),0) s from public.loyalty_ledger where customer_id = $1", [cust.id]))[0].s);
    const earned = await pts();
    expect(earned).toBeGreaterThan(0);
    await rpc(w.manager.auth, "issue_credit_note", [b.order_id, cents(b.grand_total) / 100, w.methods.cash, "all returned"]);
    expect(await pts()).toBe(0);
  });

  it("VOIDING a bill takes back the points it earned", async () => {
    const b = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 3 }), "takeaway"]);
    await rpc(w.cashier.auth, "attach_customer", [b.order_id, "9000000003", "Eve"]);
    await rpc(w.cashier.auth, "pay_order", [b.order_id, w.methods.cash, 2000]);
    const [cust] = await admin("select id from public.customers where restaurant_id = $1 and phone like '%9000000003'", [w.restaurantId]);
    await rpc(w.manager.auth, "void_order", [b.order_id, "mistake"]);
    const left = Number((await admin("select coalesce(sum(points),0) s from public.loyalty_ledger where customer_id = $1", [cust.id]))[0].s);
    expect(left, "points earned on a voided bill are not the guest's to spend").toBe(0);
  });

  it("VOIDING a bill that used points gives the points back; and a bill voided twice is not credited twice", async () => {
    const b1 = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 3 }), "takeaway"]);
    await rpc(w.cashier.auth, "attach_customer", [b1.order_id, "9000000004", "Fay"]);
    await rpc(w.cashier.auth, "pay_order", [b1.order_id, w.methods.cash, 2000]);
    const [cust] = await admin("select id from public.customers where restaurant_id = $1 and phone like '%9000000004'", [w.restaurantId]);
    const pts = async () => Number((await admin("select coalesce(sum(points),0) s from public.loyalty_ledger where customer_id = $1", [cust.id]))[0].s);
    const have = await pts();
    const b2 = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 1 }), "takeaway"]);
    await rpc(w.cashier.auth, "attach_customer", [b2.order_id, "9000000004", null]);
    await rpc(w.cashier.auth, "redeem_points", [b2.order_id, have]);
    expect(await pts()).toBe(0);
    await rpc(w.cashier.auth, "pay_order", [b2.order_id, w.methods.cash, 500]);
    const afterPaid = await pts(); // points earned on the cash part of b2
    await rpc(w.manager.auth, "void_order", [b2.order_id, "wrong guest"]);
    expect(await pts(), "the points spent come back and the points b2 earned go").toBe(have);
    await expectError(rpc(w.manager.auth, "void_order", [b2.order_id, "again"]), /already voided/i);
    expect(await pts()).toBe(have);
    expect(afterPaid).toBeGreaterThanOrEqual(0);
  });

  it("a bill voided after a gift card paid part of it returns exactly what the card paid", async () => {
    const c = await rpc(w.cashier.auth, "issue_gift_card", [200, w.methods.cash, null, null, 365]);
    const bill = await rpc(w.cashier.auth, "create_order", [items(w, { thali: 2 }), "takeaway"]);
    await rpc(w.cashier.auth, "redeem_gift_card", [bill.order_id, c.code, 150]);
    await rpc(w.cashier.auth, "pay_order", [bill.order_id, w.methods.cash, cents(bill.grand_total) / 100 - 150]);
    expect(Number((await rpc(w.cashier.auth, "gift_card_lookup", [c.code])).balance)).toBe(50);
    await rpc(w.manager.auth, "void_order", [bill.order_id, "test"]);
    expect(Number((await rpc(w.cashier.auth, "gift_card_lookup", [c.code])).balance)).toBe(200);
    const h = await rpc(w.cashier.auth, "gift_card_history", [c.code]);
    expect(h.entries.map((e: any) => e.kind).sort()).toEqual(["issue", "redeem", "void"]);
  });

  it("a refund cannot be paid out to a gift card method that has no card to credit", async () => {
    const b = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 500]);
    const gcMethod = (await admin("select id from public.payment_methods where restaurant_id = $1 and kind in ('gift_card','loyalty') limit 1", [w.restaurantId]))[0]?.id;
    expect(gcMethod, "the restaurant has a gift card payment mode").toBeTruthy();
    await expectError(rpc(w.manager.auth, "issue_credit_note", [b.order_id, 10, gcMethod, "refund to card"]), /cannot be given back to a gift card/i);
  });
});

describe.skipIf(!haveDb())("reservations and the waiting list", () => {
  let w: World, other: World;
  beforeAll(async () => {
    w = await makeWorld("res");
    other = await makeWorld("resB");
    for (const x of [w, other]) await admin("update public.restaurants set edition = 'professional' where id = $1", [x.restaurantId]);
  });
  afterAll(closePool);

  const when = (h: number) => new Date(Date.now() + h * 3600_000).toISOString();

  it("a booking needs a name and a party of at least one; no time means the waiting list", async () => {
    const id = await rpc(w.cashier.auth, "save_reservation", [null, "Meera", "98450 12345", 4, when(5), w.tableId, "window seat"]);
    const [r] = await admin("select status, phone from public.reservations where id = $1", [id]);
    expect(r.status).toBe("booked");
    const wid = await rpc(w.cashier.auth, "save_reservation", [null, "Walk-in", null, 2, null, null, ""]);
    expect((await admin("select status from public.reservations where id = $1", [wid]))[0].status).toBe("waiting");
    await expectError(rpc(w.cashier.auth, "save_reservation", [null, " ", null, 2, when(1), null, ""]), /name/i);
    await expectError(rpc(w.cashier.auth, "save_reservation", [null, "X", null, 0, when(1), null, ""]), /how many/i);
  });

  it("a huge party is refused with a message, not a database error", async () => {
    await expectError(rpc(w.cashier.auth, "save_reservation", [null, "Big party", null, 500, when(1), null, ""]), /at most 200/i);
  });

  it("a booking cannot use another restaurant's table", async () => {
    await expectError(rpc(w.cashier.auth, "save_reservation", [null, "Sly", null, 2, when(1), other.tableId, ""]), /does not exist/i);
  });

  it("seating moves a booking to a table; a cancelled booking cannot be edited", async () => {
    const id = await rpc(w.cashier.auth, "save_reservation", [null, "Ravi", null, 2, when(2), null, ""]);
    await rpc(w.cashier.auth, "set_reservation_status", [id, "seated", w.tableId]);
    const [r] = await admin("select status, dining_table_id, seated_at from public.reservations where id = $1", [id]);
    expect([r.status, r.dining_table_id]).toEqual(["seated", w.tableId]);
    expect(r.seated_at).toBeTruthy();
    await expectError(rpc(w.cashier.auth, "save_reservation", [id, "Ravi", null, 3, when(3), null, ""]), /cannot be changed/i);
    await expectError(rpc(w.cashier.auth, "set_reservation_status", [id, "teleported", null]), /Unknown status/i);
  });

  it("seating a booking at another restaurant's table is refused", async () => {
    const id = await rpc(w.cashier.auth, "save_reservation", [null, "Tess", null, 2, when(2), null, ""]);
    await expectError(rpc(w.cashier.auth, "set_reservation_status", [id, "seated", other.tableId]), /./);
    const [r] = await admin("select dining_table_id from public.reservations where id = $1", [id]);
    expect(r.dining_table_id, "no booking may point at a table that belongs to someone else").not.toBe(other.tableId);
  });

  it("another restaurant cannot change or cancel the booking", async () => {
    const id = await rpc(w.cashier.auth, "save_reservation", [null, "Zed", null, 2, when(2), null, ""]);
    await expectError(rpc(other.owner.auth, "set_reservation_status", [id, "cancelled", null]), /not found/i);
    await expectError(rpc(other.owner.auth, "save_reservation", [id, "Zed", null, 2, when(2), null, ""]), /cannot be changed/i);
  });
});

describe.skipIf(!haveDb())("deliveries and riders", () => {
  let w: World, shift: string, rider: string;
  beforeAll(async () => {
    w = await makeWorld("del");
    shift = await rpc(w.cashier.auth, "open_shift", [0]);
    rider = await rpc(w.cashier.auth, "rider_save", [null, "Suresh", "9811111111", true]);
  });
  afterAll(closePool);

  const deliveryBill = async (addr = "12 MG Road") => {
    const r = await rpc(w.cashier.auth, "create_order", [items(w, { biryani: 1 }), "delivery", null, null, null, null, 0, null, null, null, null, null, { address: addr, guest_name: "Kiran", guest_phone: "9822222222" }]).catch(async () =>
      rpc(w.cashier.auth, "create_order", [items(w, { biryani: 1 }), "delivery"]));
    return r;
  };

  it("a rider needs a name; a rider can be switched off and then cannot be sent out", async () => {
    await expectError(rpc(w.cashier.auth, "rider_save", [null, " ", null, true]), /name/i);
    const r2 = await rpc(w.cashier.auth, "rider_save", [null, "Old Hand", null, true]);
    await rpc(w.cashier.auth, "rider_save", [r2, "Old Hand", null, false]);
    const b = await deliveryBill();
    await expectError(rpc(w.cashier.auth, "delivery_update", [b.order_id, "out", r2]), /rider was not found/i);
  });

  it("a bill goes out with a rider, comes back delivered, and then the rider settles the cash", async () => {
    const b = await deliveryBill();
    await expectError(rpc(w.cashier.auth, "delivery_update", [b.order_id, "out", null]), /Choose the rider/i);
    await rpc(w.cashier.auth, "delivery_update", [b.order_id, "out", rider]);
    await rpc(w.cashier.auth, "delivery_update", [b.order_id, "delivered", null]);
    const s = await rpc(w.cashier.auth, "rider_settle", [rider]);
    expect(s.bills).toBeGreaterThanOrEqual(1);
    const [o] = await admin("select payment_status, paid_total, grand_total from public.orders where id = $1", [b.order_id]);
    expect(o.payment_status).toBe("paid");
    const pays = await admin("select p.amount, p.shift_id, pm.kind from public.payments p join public.payment_methods pm on pm.id = p.payment_method_id where p.order_id = $1", [b.order_id]);
    expect(pays.map((x) => [cents(x.amount), x.kind, x.shift_id])).toEqual([[cents(b.grand_total), "cash", shift]]);
    await expectError(rpc(w.cashier.auth, "rider_settle", [rider]), /no delivered bills/i);
  });

  it("a voided bill cannot be sent out; a dine-in bill is not a delivery", async () => {
    const b = await deliveryBill();
    await rpc(w.manager.auth, "void_order", [b.order_id, "guest cancelled"]);
    await expectError(rpc(w.cashier.auth, "delivery_update", [b.order_id, "out", rider]), /voided/i);
    const d = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 1 }), "dine_in", w.tableId]);
    await expectError(rpc(w.cashier.auth, "delivery_update", [d.order_id, "out", rider]), /not a delivery/i);
    await rpc(w.cashier.auth, "pay_order", [d.order_id, w.methods.cash, 500]);
  });

  it("a delivered bill that was voided afterwards is not collected from the rider", async () => {
    const b = await deliveryBill();
    await rpc(w.cashier.auth, "delivery_update", [b.order_id, "delivered", rider]);
    await rpc(w.manager.auth, "void_order", [b.order_id, "never reached"]);
    await expectError(rpc(w.cashier.auth, "rider_settle", [rider]), /no delivered bills/i);
  });

  it("a returned delivery goes back to waiting and the rider is cleared", async () => {
    const b = await deliveryBill();
    await rpc(w.cashier.auth, "delivery_update", [b.order_id, "out", rider]);
    await rpc(w.cashier.auth, "delivery_update", [b.order_id, "returned", null]);
    await rpc(w.cashier.auth, "delivery_update", [b.order_id, "waiting", null]);
    const [o] = await admin("select delivery_status, rider_id from public.orders where id = $1", [b.order_id]);
    expect([o.delivery_status, o.rider_id]).toEqual(["waiting", null]);
  });

  it("another restaurant's rider or bill is out of reach", async () => {
    const other = await makeWorld("delB");
    await rpc(other.cashier.auth, "open_shift", [0]);
    const b = await deliveryBill();
    await expectError(rpc(other.cashier.auth, "delivery_update", [b.order_id, "out", rider]), /not a delivery bill/i);
    await expectError(rpc(other.cashier.auth, "rider_settle", [rider]), /rider was not found/i);
    await expectError(rpc(other.cashier.auth, "rider_save", [rider, "Stolen", null, true]), /not found/i);
  });
});

describe.skipIf(!haveDb())("pre-orders: book now, take an advance, bill when collected", () => {
  let w: World, shift: string;
  const due = (h = 48) => new Date(Date.now() + h * 3600_000).toISOString();
  const book = (spec: Record<string, number>, extra: object = {}) =>
    rpc(w.cashier.auth, "pre_order_save", [{ guest_name: "Latha", guest_phone: "9833333333", due_at: due(), order_type: "takeaway", address: "", note: "", items: items(w, spec), ...extra }]);

  beforeAll(async () => {
    w = await makeWorld("pre");
    shift = await rpc(w.cashier.auth, "open_shift", [0]);
  });
  afterAll(closePool);

  it("a pre-order needs a name, a time in the future (but not years away) and an address for delivery", async () => {
    await expectError(book({ dosa: 1 }, { guest_name: " " }), /name/i);
    await expectError(book({ dosa: 1 }, { due_at: new Date(Date.now() - 3600_000).toISOString() }), /past/i);
    await expectError(book({ dosa: 1 }, { due_at: new Date(Date.now() + 400 * 86400_000).toISOString() }), /180 days/i);
    await expectError(book({ dosa: 1 }, { order_type: "delivery", address: "" }), /address/i);
    await expectError(rpc(w.cashier.auth, "pre_order_save", [{ guest_name: "X", due_at: due(), order_type: "takeaway", items: [] }]), /./);
  });

  it("numbers count up; the estimate matches what a bill for the same dishes costs", async () => {
    const a = await book({ dosa: 2 });
    const b = await book({ dosa: 2 });
    expect(b.number).toBe(a.number + 1);
    const q = await rpc(w.cashier.auth, "quote_order", [items(w, { dosa: 2 })]);
    expect(cents(a.estimate)).toBe(cents(q.grand_total));
  });

  it("an advance in cash goes into the drawer; the held amount grows; UPI does not touch the drawer", async () => {
    const p = await book({ biryani: 2 });
    const before = await drawerCash(shift);
    const r = await rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.cash, 200, null]);
    expect(cents(r.held)).toBe(20000);
    expect(await drawerCash(shift)).toBe(before + 20000);
    await rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.upi, 100, "UPI-77"]);
    expect(await drawerCash(shift)).toBe(before + 20000);
    await expectError(rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.cash, 0, null]), /advance amount/i);
    await expectError(rpc(w.cashier.auth, "pre_order_advance", [p.id, uuid(), 10, null]), /how the guest paid/i);
  });

  it("billing applies the advance: the bill shows what is still to pay and the day closes cleanly", async () => {
    const p = await book({ biryani: 2 });
    await rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.cash, 200, null]);
    const r = await rpc(w.cashier.auth, "pre_order_bill", [p.id]);
    expect(cents(r.advance_applied)).toBe(20000);
    expect(cents(r.balance)).toBe(cents(r.total) - 20000);
    const [o] = await admin("select payment_status, paid_total from public.orders where id = $1", [r.order_id]);
    expect(o.payment_status).toBe("partial");
    const pay = await rpc(w.cashier.auth, "pay_order", [r.order_id, w.methods.cash, cents(r.balance) / 100]);
    expect(pay.paid).toBe(true);
    await expectError(rpc(w.cashier.auth, "pre_order_bill", [p.id]), /already billed/i);
    await expectError(rpc(w.cashier.auth, "pre_order_cancel", [p.id, "late", w.methods.cash]), /already billed/i);
  });

  it("an advance larger than the bill: the leftover is handed back and recorded, not left hanging", async () => {
    const p = await book({ dosa: 1 });
    await rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.cash, 1000, null]);
    const before = await drawerCash(shift);
    const r = await rpc(w.cashier.auth, "pre_order_bill", [p.id]);
    expect(cents(r.advance_applied)).toBe(cents(r.total));
    expect(cents(r.advance_left_over)).toBe(100000 - cents(r.total));
    const [o] = await admin("select payment_status from public.orders where id = $1", [r.order_id]);
    expect(o.payment_status).toBe("paid");
    // the guest was given the leftover back, so the drawer must say so
    expect(await drawerCash(shift), "the leftover advance has left the drawer").toBe(before - (100000 - cents(r.total)));
  });

  it("an advance paid by UPI that is more than the bill is handed back by UPI: recorded, and the drawer is untouched", async () => {
    const p = await book({ dosa: 1 });
    await rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.upi, 500, "UPI-5"]);
    const before = await drawerCash(shift);
    const r = await rpc(w.cashier.auth, "pre_order_bill", [p.id]);
    expect(cents(r.advance_handed_back)).toBe(50000 - cents(r.total));
    expect(await drawerCash(shift)).toBe(before);
    const refunds = await admin("select pm.kind, amount from public.pre_order_payments x join public.payment_methods pm on pm.id = x.payment_method_id where pre_order_id = $1 and x.kind = 'refund'", [p.id]);
    expect(refunds.map((x) => [x.kind, cents(x.amount)])).toEqual([["upi", 50000 - cents(r.total)]]);
    const pl = (await rpc(w.cashier.auth, "pre_orders_list", ["all"])).find((x: any) => x.id === p.id);
    expect(cents(pl.advance), "what stays on the pre-order is exactly what went to the bill").toBe(cents(r.total));
  });

  it("an advance in two ways (cash then UPI) more than the bill is handed back newest first", async () => {
    const p = await book({ dosa: 1 });
    await rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.cash, 100, null]);
    await new Promise((r) => setTimeout(r, 20));
    await rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.upi, 200, "U"]);
    const r = await rpc(w.cashier.auth, "pre_order_bill", [p.id]);
    const back = cents(r.advance_handed_back);
    expect(back).toBe(30000 - cents(r.total));
    const refunds = await admin("select pm.kind, x.amount from public.pre_order_payments x join public.payment_methods pm on pm.id = x.payment_method_id where pre_order_id = $1 and x.kind = 'refund' order by pm.kind", [p.id]);
    expect(refunds.reduce((s, x) => s + cents(x.amount), 0)).toBe(back);
  });

  it("cancelling gives the whole advance back (by the method the cashier picks) and needs a reason", async () => {
    const p = await book({ biryani: 1 });
    await rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.cash, 150, null]);
    await expectError(rpc(w.cashier.auth, "pre_order_cancel", [p.id, " ", w.methods.cash]), /why/i);
    await expectError(rpc(w.cashier.auth, "pre_order_cancel", [p.id, "guest changed plans", null]), /how the advance/i);
    const before = await drawerCash(shift);
    const r = await rpc(w.cashier.auth, "pre_order_cancel", [p.id, "guest changed plans", w.methods.cash]);
    expect(cents(r.refunded)).toBe(15000);
    expect(await drawerCash(shift)).toBe(before - 15000);
    await expectError(rpc(w.cashier.auth, "pre_order_advance", [p.id, w.methods.cash, 10, null]), /already cancelled/i);
  });

  it("two tills billing the same pre-order at once make one bill", async () => {
    const p = await book({ dosa: 1 });
    const res = await Promise.allSettled([rpc(w.cashier.auth, "pre_order_bill", [p.id]), rpc(w.manager.auth, "pre_order_bill", [p.id])]);
    expect(res.filter((r) => r.status === "fulfilled")).toHaveLength(1);
    expect((await admin("select count(*)::int n from public.orders where id in (select order_id from public.pre_orders where id = $1)", [p.id]))[0].n).toBe(1);
  });

  it("an edit changes the estimate; a billed pre-order cannot be edited; the list shows today's bookings", async () => {
    const p = await book({ dosa: 1 });
    const e = await rpc(w.cashier.auth, "pre_order_save", [{ id: p.id, guest_name: "Latha", guest_phone: "9833333333", due_at: due(60), order_type: "takeaway", items: items(w, { dosa: 3 }) }]);
    expect(cents(e.estimate)).toBeGreaterThan(cents(p.estimate));
    await rpc(w.cashier.auth, "pre_order_bill", [p.id]);
    await expectError(rpc(w.cashier.auth, "pre_order_save", [{ id: p.id, guest_name: "Latha", due_at: due(60), order_type: "takeaway", items: items(w, { dosa: 1 }) }]), /not open for changes/i);
    const list = await rpc(w.cashier.auth, "pre_orders_list", ["all"]);
    expect(list.some((x: any) => x.id === p.id && x.status === "billed")).toBe(true);
  });

  it("another restaurant cannot see or touch the booking", async () => {
    const other = await makeWorld("preB");
    await rpc(other.cashier.auth, "open_shift", [0]);
    const p = await book({ dosa: 1 });
    await expectError(rpc(other.cashier.auth, "pre_order_bill", [p.id]), /not found/i);
    await expectError(rpc(other.cashier.auth, "pre_order_cancel", [p.id, "no", other.methods.cash]), /not found/i);
    expect((await rpc(other.cashier.auth, "pre_orders_list", ["all"]))).toEqual([]);
  });
});

describe.skipIf(!haveDb())("QR table ordering and kiosks: a guest with no login, and the staff who accept", () => {
  let w: World, token: string, kioskToken: string, kioskUser: string;
  beforeAll(async () => {
    w = await makeWorld("qr");
    await modules(w, "qr_ordering");
    await rpc(w.cashier.auth, "open_shift", [0]);
    token = (await admin("select qr_token from public.dining_tables where id = $1", [w.tableId]))[0].qr_token;
    if (!token) {
      token = "tok" + uuid().replace(/-/g, "");
      await admin("update public.dining_tables set qr_token = $1 where id = $2", [token, w.tableId]);
    }
  });
  afterAll(closePool);

  const lines = (k: string, qty = 1) => [{ product_id: w.products[k].id, qty, options: [], note: "" }];

  it("a guest sees the menu with the prices staff will actually charge", async () => {
    const m = await asGuest(  "qr_menu", [token]);
    const dishes = m.categories.flatMap((c: any) => c.items);
    expect(dishes.map((d: any) => d.name).sort()).toEqual(["Chicken Biryani", "Cola", "Masala Dosa", "Veg Thali"]);
    expect(m.table).toBe("T1");
  });

  it("a happy-hour offer shows on the guest's menu as it does on the till", async () => {
    await rpc(w.owner.auth, "save_price_rule", [{ name: "All day half off dosa", days: [1, 2, 3, 4, 5, 6, 7], start_time: "00:00", end_time: "23:59", kind: "percent_off", value: 50, product_ids: [w.products.dosa.id], category_ids: [] }]);
    const till = await rpc(w.cashier.auth, "quote_order", [items(w, { dosa: 1 })]);
    const m = await asGuest("qr_menu", [token]);
    const dosa = m.categories.flatMap((c: any) => c.items).find((d: any) => d.name === "Masala Dosa");
    const est = await asGuest("qr_place_order", [token, lines("dosa"), "Guest", ""]);
    expect(cents(est.estimated_total), "the guest's estimate agrees with the till").toBe(cents(till.grand_total));
    expect(Number(dosa.price), "the price the guest SEES agrees with the offer").toBe(60);
    await admin("delete from public.price_rules where restaurant_id = $1", [w.restaurantId]);
    await rpc(w.manager.auth, "reject_qr_order", [est.request_id, "test"]);
  });

  it("a guest cannot order from a QR code that is wrong, off, or too short", async () => {
    await expectError(asGuest("qr_menu", ["short"]), /not valid/i);
    await expectError(asGuest("qr_menu", ["x".repeat(30)]), /not active/i);
    await admin("delete from public.restaurant_modules where restaurant_id = $1 and module_key = 'qr_ordering'", [w.restaurantId]);
    await expectError(asGuest("qr_menu", [token]), /not active/i);
    await modules(w, "qr_ordering");
  });

  it("a guest's order is checked: empty, too many lines, silly quantities, dishes that are not on the menu", async () => {
    await expectError(asGuest("qr_place_order", [token, [], "", ""]), /empty/i);
    await expectError(asGuest("qr_place_order", [token, lines("dosa", 0), "", ""]), /whole number/i);
    await expectError(asGuest("qr_place_order", [token, lines("dosa", 21), "", ""]), /whole number/i);
    await expectError(asGuest("qr_place_order", [token, lines("dosa", 1.5), "", ""]), /whole number/i);
    await expectError(asGuest("qr_place_order", [token, [{ product_id: uuid(), qty: 1 }], "", ""]), /./);
    const other = await makeWorld("qrB");
    await expectError(asGuest("qr_place_order", [token, [{ product_id: other.products.dosa.id, qty: 1 }], "", ""]), /./);
  });

  it("a table cannot be flooded: after three waiting orders the guest is asked to wait", async () => {
    await admin("update public.qr_orders set status = 'rejected' where dining_table_id = $1 and status = 'pending'", [w.tableId]);
    for (let i = 0; i < 3; i++) await asGuest("qr_place_order", [token, lines("cola"), "G", ""]);
    await expectError(asGuest("qr_place_order", [token, lines("cola"), "G", ""]), /already has orders waiting/i);
    await admin("update public.qr_orders set status = 'rejected' where dining_table_id = $1 and status = 'pending'", [w.tableId]);
  });

  it("staff accept: it becomes one bill for the table; a second order adds to the same bill; a rejected one never reaches the kitchen", async () => {
    const a = await asGuest("qr_place_order", [token, lines("dosa", 2), "Anu", "no onion"]);
    const st0 = await asGuest("qr_order_status", [a.request_id, a.key]);
    expect(st0.status).toBe("pending");
    expect(await asGuest("qr_order_status", [a.request_id, "wrong-key"])).toBeNull();
    const acc = await rpc(w.cashier.auth, "accept_qr_order", [a.request_id]);
    expect(acc.added).toBeUndefined();
    const b = await asGuest("qr_place_order", [token, lines("cola"), "Anu", ""]);
    const acc2 = await rpc(w.cashier.auth, "accept_qr_order", [b.request_id]);
    expect(acc2.added).toBe(true);
    expect(acc2.order_id).toBe(acc.order_id);
    const st = await asGuest("qr_order_status", [a.request_id, a.key]);
    expect(st.status).toBe("accepted");
    expect(st.bill_number).toBeTruthy();
    const c = await asGuest("qr_place_order", [token, lines("thali"), "Anu", ""]);
    await rpc(w.cashier.auth, "reject_qr_order", [c.request_id, "out of thali"]);
    expect((await asGuest("qr_order_status", [c.request_id, c.key])).status).toBe("rejected");
    await expectError(rpc(w.cashier.auth, "accept_qr_order", [c.request_id]), /already rejected/i);
    await expectError(rpc(w.cashier.auth, "accept_qr_order", [a.request_id]), /already accepted/i);
    const [{ n }] = await admin("select count(*)::int n from public.order_items where order_id = $1", [acc.order_id]);
    expect(n).toBe(2);
    await rpc(w.cashier.auth, "pay_order", [acc.order_id, w.methods.cash, 1000]);
  });

  it("the guest's note reaches the kitchen on the first dish", async () => {
    const a = await asGuest("qr_place_order", [token, lines("biryani"), "Anu", "extra spicy"]);
    const acc = await rpc(w.cashier.auth, "accept_qr_order", [a.request_id]);
    const [it] = await admin("select kitchen_note as note from public.order_items where order_id = $1 order by created_at limit 1", [acc.order_id]);
    expect(it.note).toMatch(/extra spicy/);
    await rpc(w.cashier.auth, "pay_order", [acc.order_id, w.methods.cash, 1000]);
  });

  it("another restaurant's staff cannot accept or reject a table's order", async () => {
    const other = await makeWorld("qrC");
    await modules(other, "qr_ordering");
    await rpc(other.cashier.auth, "open_shift", [0]);
    await admin("update public.qr_orders set created_at = now() - interval '1 hour' where dining_table_id = $1", [w.tableId]); // the per-table rate limit is its own test
    const a = await asGuest("qr_place_order", [token, lines("dosa"), "Q", ""]);
    await expectError(rpc(other.cashier.auth, "accept_qr_order", [a.request_id]), /does not exist/i);
    await expectError(rpc(other.cashier.auth, "reject_qr_order", [a.request_id, "no"]), /not waiting/i);
    await rpc(w.cashier.auth, "reject_qr_order", [a.request_id, "cleanup"]);
  });

  it("a kiosk: set up by someone with settings rights; a guest's order is accepted at once and is a takeaway bill", async () => {
    await expectError(rpc(w.cashier.auth, "kiosk_add", ["Kiosk 1"]), /allow|permission|right/i);
    const k = await rpc(w.owner.auth, "kiosk_add", ["Kiosk 1"]);
    kioskToken = k.token;
    await expectError(rpc(w.owner.auth, "kiosk_add", ["kiosk 1"]), /already/i);
    // the kiosk signs in as a staff member (the counter user); the Kiosk screen sets this up
    const hasCol = (await admin("select 1 from information_schema.columns where table_name = 'dining_tables' and column_name = 'kiosk_user_id'")).length > 0;
    expect(hasCol).toBe(true);
    kioskUser = w.cashier.userId;
    await admin("update public.dining_tables set kiosk_user_id = $1 where qr_token = $2", [kioskUser, kioskToken]);
    const m = await asGuest("qr_menu", [kioskToken]);
    expect(m.kiosk).toBe(true);
    const o = await asGuest("qr_place_order", [kioskToken, lines("dosa", 2), "Walk-in", ""]);
    const st = await asGuest("qr_order_status", [o.request_id, o.key]);
    expect(st.status, "kiosk orders are accepted without staff").toBe("accepted");
    expect(st.bill_number).toBeTruthy();
    const [bill] = await admin("select order_type, dining_table_id, payment_status from public.orders where bill_number = $1 and restaurant_id = $2", [st.bill_number, w.restaurantId]);
    expect(bill.order_type).toBe("takeaway");
    expect(bill.payment_status).toBe("unpaid");
    await rpc(w.cashier.auth, "pay_order", [(await admin("select id from public.orders where bill_number = $1 and restaurant_id = $2", [st.bill_number, w.restaurantId]))[0].id, w.methods.cash, 1000]);
  });

  it("kiosk settings: only a real staff login with the right can be chosen; a removed kiosk stops taking orders", async () => {
    const k = await rpc(w.owner.auth, "kiosk_add", ["Kiosk 2"]);
    await expectError(rpc(w.cashier.auth, "kiosk_set_auto", [k.id, w.cashier.userId]), /allow|permission|right/i);
    await expectError(rpc(w.owner.auth, "kiosk_set_auto", [k.id, uuid()]), /Choose an active staff login/i);
    await rpc(w.owner.auth, "kiosk_set_auto", [k.id, w.manager.userId]);
    expect((await rpc(w.owner.auth, "kiosk_list", [])).find((x: any) => x.id === k.id).auto_user).toBe(w.manager.userId);
    expect(await rpc(w.cashier.auth, "kiosk_list", [])).toEqual([]);
    await rpc(w.owner.auth, "kiosk_remove", [k.id]);
    await expectError(asGuest("qr_menu", [k.token]), /not active/i);
    const other = await makeWorld("qrD");
    await modules(other, "qr_ordering");
    await expectError(rpc(other.owner.auth, "kiosk_remove", [k.id]), /not found/i);
    await expectError(rpc(other.owner.auth, "kiosk_set_auto", [k.id, null]), /not found/i);
  });

  it("a kiosk whose staff login is switched off leaves the order waiting for staff instead of losing it", async () => {
    await admin("update public.users set is_active = false where id = $1", [kioskUser]);
    const o = await asGuest("qr_place_order", [kioskToken, lines("cola"), "Walk-in", ""]);
    expect((await asGuest("qr_order_status", [o.request_id, o.key])).status).toBe("pending");
    await admin("update public.users set is_active = true where id = $1", [kioskUser]);
    await rpc(w.manager.auth, "accept_qr_order", [o.request_id]).then(async (r: any) => rpc(w.manager.auth, "pay_order", [r.order_id, w.methods.cash, 500]));
  });
});

describe.skipIf(!haveDb())("gift card expiry follows the restaurant's calendar, not the database's", () => {
  let w: World;
  beforeAll(async () => {
    w = await makeWorld("gct");
    await modules(w, "loyalty");
    await rpc(w.cashier.auth, "open_shift", [0]);
  });
  afterAll(closePool);

  const localToday = async (tz: string) => (await admin("select (now() at time zone $1)::date::text d", [tz]))[0].d as string;
  const addDays = async (d: string, n: number) => (await admin("select ($1::date + $2::int)::text d", [d, n]))[0].d as string;

  // At any moment these two zones cannot both share the database's (UTC) date, so one of them proves the point.
  for (const tz of ["Pacific/Kiritimati", "Pacific/Pago_Pago", "Asia/Kolkata"]) {
    it(`in ${tz}: a card valid for 30 days expires 30 days from the restaurant's today; the day it expires it still works, the next day it does not`, async () => {
      await admin("update public.restaurants set timezone = $1 where id = $2", [tz, w.restaurantId]);
      const today = await localToday(tz);
      const c = await rpc(w.cashier.auth, "issue_gift_card", [100, w.methods.cash, null, null, 30]);
      expect(c.expires_on).toBe(await addDays(today, 30));
      // expires today (restaurant's date): still usable
      await admin("update public.gift_cards set expires_on = $1 where code = $2 and restaurant_id = $3", [today, c.code, w.restaurantId]);
      expect((await rpc(w.cashier.auth, "gift_card_lookup", [c.code])).expired).toBe(false);
      const bill = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 1 }), "takeaway"]);
      const r = await rpc(w.cashier.auth, "redeem_gift_card", [bill.order_id, c.code, null]);
      expect(Number(r.used)).toBeGreaterThan(0);
      await rpc(w.cashier.auth, "pay_order", [bill.order_id, w.methods.cash, 500]).catch(() => {});
      // expired yesterday (restaurant's date)
      await admin("update public.gift_cards set expires_on = $1 where code = $2 and restaurant_id = $3", [await addDays(today, -1), c.code, w.restaurantId]);
      expect((await rpc(w.cashier.auth, "gift_card_lookup", [c.code])).expired).toBe(true);
    });
  }
});
