import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, haveDb, rpc, uuid } from "./support/db";
import { expectError } from "./support/oracle";
import { items, makeWorld, type World } from "./support/world";

const cents = (x: unknown) => Math.round(Number(x) * 100);
const stockOf = async (w: World, ing: string) =>
  Number((await admin("select coalesce(sum(qty),0) s from public.stock_movements where branch_id = $1 and ingredient_id = $2", [w.branchId, ing]))[0].s);

describe.skipIf(!haveDb())("stock: ingredients, recipes, counts and wastage", () => {
  let w: World, rice: string, oil: string;
  beforeAll(async () => {
    w = await makeWorld("stk");
    await admin("update public.restaurants set edition = 'professional' where id = $1", [w.restaurantId]);
    await rpc(w.cashier.auth, "open_shift", [0]);
  });
  afterAll(closePool);

  it("an owner or manager adds ingredients; a cashier cannot", async () => {
    rice = await rpc(w.manager.auth, "save_ingredient", [null, "Rice", "kg", 60, 5, "Dry goods"]);
    oil = await rpc(w.owner.auth, "save_ingredient", [null, "Oil", "l", 150, 2, ""]);
    expect(rice).toBeTruthy();
    await expectError(rpc(w.cashier.auth, "save_ingredient", [null, "Salt", "kg", 20, 1, ""]), /allow|permission|right/i);
  });

  it("two ingredients cannot share a name, and a name is required", async () => {
    await expectError(rpc(w.manager.auth, "save_ingredient", [null, " rice ", "kg", 1, 1, ""]), /already exists/i);
    await expectError(rpc(w.manager.auth, "save_ingredient", [null, "  ", "kg", 1, 1, ""]), /name/i);
  });

  it("a negative cost or reorder level is refused", async () => {
    await expectError(rpc(w.manager.auth, "save_ingredient", [null, "Bad cost", "kg", -5, 1, ""]), /./);
    await expectError(rpc(w.manager.auth, "save_ingredient", [null, "Bad reorder", "kg", 5, -1, ""]), /./);
  });

  it("editing an ingredient keeps its history and cannot touch another restaurant's", async () => {
    const other = await makeWorld("stkB");
    await admin("update public.restaurants set edition = 'professional' where id = $1", [other.restaurantId]);
    await expectError(rpc(other.owner.auth, "save_ingredient", [rice, "Hacked", "kg", 1, 1, ""]), /not found/i);
    const id = await rpc(w.manager.auth, "save_ingredient", [rice, "Rice", "kg", 60, 5, "Grains"]);
    expect(id).toBe(rice);
  });

  it("purchase raises stock and blends the cost; wastage lowers it; a count sets it exactly", async () => {
    let r = await rpc(w.manager.auth, "record_stock", [rice, "purchase", 10, 60, "first delivery"]);
    expect(Number(r.stock)).toBe(10);
    r = await rpc(w.manager.auth, "record_stock", [rice, "purchase", 10, 80, null]);
    expect(Number(r.stock)).toBe(20);
    const [{ cost_per_unit }] = await admin("select cost_per_unit from public.ingredients where id = $1", [rice]);
    expect(Number(cost_per_unit)).toBe(70); // (10*60 + 10*80) / 20
    r = await rpc(w.manager.auth, "record_stock", [rice, "wastage", 2.5, null, "spilled"]);
    expect(Number(r.stock)).toBe(17.5);
    r = await rpc(w.manager.auth, "record_stock", [rice, "count", 16, null, "stock take"]);
    expect(Number(r.stock)).toBe(16);
    expect(await stockOf(w, rice)).toBe(16);
  });

  it("bad stock entries are refused: zero or negative quantity, unknown kind", async () => {
    await expectError(rpc(w.manager.auth, "record_stock", [rice, "purchase", 0, 10, null]), /quantity/i);
    await expectError(rpc(w.manager.auth, "record_stock", [rice, "wastage", -3, null, null]), /quantity/i);
    await expectError(rpc(w.manager.auth, "record_stock", [rice, "gift", 3, null, null]), /choose/i);
    await expectError(rpc(w.cashier.auth, "record_stock", [rice, "wastage", 1, null, null]), /allow|permission|right/i);
    expect(await stockOf(w, rice)).toBe(16);
  });

  it("wastage can take stock below zero (the screen should show it); the count is the way back", async () => {
    const id = await rpc(w.manager.auth, "save_ingredient", [null, "Saffron", "g", 500, 0, ""]);
    const r = await rpc(w.manager.auth, "record_stock", [id, "wastage", 3, null, null]);
    expect(Number(r.stock)).toBe(-3);
    const c = await rpc(w.manager.auth, "record_stock", [id, "count", 0, null, null]);
    expect(Number(c.stock)).toBe(0);
  });

  it("a recipe makes a sale use up ingredients; cancelling part of the line puts back only that part; a void puts back the rest", async () => {
    await rpc(w.manager.auth, "save_recipe", [w.products.dosa.id, [{ ingredient_id: rice, qty: 0.2 }, { ingredient_id: oil, qty: 0.05 }]]);
    await rpc(w.manager.auth, "record_stock", [oil, "purchase", 5, 150, null]);
    const before = { rice: await stockOf(w, rice), oil: await stockOf(w, oil) };

    const bill = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 4 }), "dine_in", w.tableId]);
    expect(await stockOf(w, rice)).toBeCloseTo(before.rice - 0.8, 6);
    expect(await stockOf(w, oil)).toBeCloseTo(before.oil - 0.2, 6);

    const [{ id: itemId }] = await admin("select id from public.order_items where order_id = $1", [bill.order_id]);
    await rpc(w.manager.auth, "cancel_order_item", [itemId, 1, "guest changed mind"]);
    expect(await stockOf(w, rice), "only the one cancelled portion comes back").toBeCloseTo(before.rice - 0.6, 6);

    await rpc(w.manager.auth, "void_order", [bill.order_id, "test void"]);
    expect(await stockOf(w, rice), "voiding puts back everything that was still used").toBeCloseTo(before.rice, 6);
    expect(await stockOf(w, oil)).toBeCloseTo(before.oil, 6);
  });

  it("changing a recipe does not rewrite what past bills used", async () => {
    const bill = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 200]);
    const usedBefore = await admin("select ingredient_id, qty from public.stock_movements where order_id = $1 order by ingredient_id", [bill.order_id]);
    await rpc(w.manager.auth, "save_recipe", [w.products.dosa.id, [{ ingredient_id: rice, qty: 0.5 }]]);
    const usedAfter = await admin("select ingredient_id, qty from public.stock_movements where order_id = $1 order by ingredient_id", [bill.order_id]);
    expect(usedAfter).toEqual(usedBefore);
  });

  it("a recipe line for another restaurant's ingredient is ignored, not saved", async () => {
    const other = await makeWorld("stkC");
    await admin("update public.restaurants set edition = 'professional' where id = $1", [other.restaurantId]);
    const foreign = await rpc(other.owner.auth, "save_ingredient", [null, "Foreign", "kg", 1, 0, ""]);
    const n = await rpc(w.manager.auth, "save_recipe", [w.products.cola.id, [{ ingredient_id: foreign, qty: 1 }]]);
    expect(Number(n)).toBe(0);
  });

  it("the Stock screens are closed on a plan without Stock", async () => {
    await admin("update public.restaurants set edition = 'basic' where id = $1", [w.restaurantId]);
    await expectError(rpc(w.manager.auth, "record_stock", [rice, "purchase", 1, 1, null]), /plan|module|feature|upgrade|not included/i);
    await admin("update public.restaurants set edition = 'professional' where id = $1", [w.restaurantId]);
  });
});

describe.skipIf(!haveDb())("purchases: suppliers, orders, receiving goods and paying for them", () => {
  let w: World, rice: string, oil: string, sup: string, shift: string;
  const lines = (r: number, o: number, rc = 60, oc = 150) => [{ ingredient_id: rice, qty: r, unit_cost: rc }, { ingredient_id: oil, qty: o, unit_cost: oc }];

  beforeAll(async () => {
    w = await makeWorld("pur");
    await admin("update public.restaurants set edition = 'professional' where id = $1", [w.restaurantId]);
    shift = await rpc(w.cashier.auth, "open_shift", [1000]);
    rice = await rpc(w.manager.auth, "save_ingredient", [null, "Rice", "kg", 60, 5, ""]);
    oil = await rpc(w.manager.auth, "save_ingredient", [null, "Oil", "l", 150, 2, ""]);
    sup = (await rpc(w.manager.auth, "save_supplier", [null, { name: "Ravi Traders", payment_days: 15, is_active: true }]));
  });
  afterAll(closePool);

  const grn = async (id: string) => (await admin("select * from public.goods_receipts where id = $1", [id]))[0];

  it("a supplier needs a name; a cashier cannot add one", async () => {
    expect(sup).toBeTruthy();
    await expectError(rpc(w.manager.auth, "save_supplier", [null, { name: " " }]), /name/i);
    await expectError(rpc(w.cashier.auth, "save_supplier", [null, { name: "X" }]), /allow|permission|right/i);
  });

  it("a purchase order saved as a draft can be changed; once sent it cannot", async () => {
    const d = await rpc(w.manager.auth, "save_purchase_order", [null, sup, lines(10, 4), null, "weekly", false]);
    expect(d.status).toBe("draft");
    expect(cents(d.total)).toBe(cents(10 * 60 + 4 * 150));
    const d2 = await rpc(w.manager.auth, "save_purchase_order", [d.id, sup, lines(20, 4), null, "weekly", true]);
    expect(d2.status).toBe("ordered");
    expect(cents(d2.total)).toBe(cents(20 * 60 + 4 * 150));
    await expectError(rpc(w.manager.auth, "save_purchase_order", [d.id, sup, lines(1, 1), null, "", false]), /already been sent/i);
  });

  it("the same ingredient twice, zero quantity or a missing ingredient is refused", async () => {
    await expectError(rpc(w.manager.auth, "save_purchase_order", [null, sup, [{ ingredient_id: rice, qty: 1 }, { ingredient_id: rice, qty: 2 }], null, "", false]), /twice/i);
    await expectError(rpc(w.manager.auth, "save_purchase_order", [null, sup, [{ ingredient_id: rice, qty: 0 }], null, "", false]), /quantity/i);
    await expectError(rpc(w.manager.auth, "save_purchase_order", [null, sup, [{ ingredient_id: uuid(), qty: 1 }], null, "", false]), /no longer exists/i);
    await expectError(rpc(w.manager.auth, "save_purchase_order", [null, sup, [], null, "", false]), /at least one/i);
  });

  let po: { id: string; number: string };
  it("goods received against an order move stock, set the order to part-received and then received", async () => {
    po = await rpc(w.manager.auth, "save_purchase_order", [null, sup, lines(20, 4), null, "", true]);
    const r1 = await rpc(w.manager.auth, "receive_goods", [sup, lines(12, 4), po.id, "INV-1", null, 0, 0, null, null, null, uuid()]);
    expect(r1.purchase_order_status).toBe("part_received");
    expect(cents(r1.total)).toBe(cents(12 * 60 + 4 * 150));
    const ricePart = Number((await admin("select received_qty from public.purchase_order_lines where purchase_order_id = $1 and ingredient_id = $2", [po.id, rice]))[0].received_qty);
    expect(ricePart).toBe(12);
    const r2 = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 8, unit_cost: 60 }], po.id, "INV-2", null, 0, 0, null, null, null, uuid()]);
    expect(r2.purchase_order_status).toBe("received");
    expect(await stockOf(w, rice)).toBe(20);
    expect(await stockOf(w, oil)).toBe(4);
  });

  it("goods cannot be received against an order that is finished, cancelled or for another supplier", async () => {
    await expectError(rpc(w.manager.auth, "receive_goods", [sup, lines(1, 1), po.id, null, null, 0, 0, null, null, null, uuid()]), /received|cannot be received/i);
    const sup2 = await rpc(w.manager.auth, "save_supplier", [null, { name: "Other Co", payment_days: 0, is_active: true }]);
    const po2 = await rpc(w.manager.auth, "save_purchase_order", [null, sup2, lines(5, 1), null, "", true]);
    await expectError(rpc(w.manager.auth, "receive_goods", [sup, lines(1, 1), po2.id, null, null, 0, 0, null, null, null, uuid()]), /another supplier/i);
    await rpc(w.manager.auth, "set_purchase_order_status", [po2.id, "cancel"]);
    await expectError(rpc(w.manager.auth, "receive_goods", [sup2, lines(1, 1), po2.id, null, null, 0, 0, null, null, null, uuid()]), /cancelled/i);
  });

  it("saving the same receipt twice (a second tap) records it once", async () => {
    const ref = uuid();
    const before = await stockOf(w, rice);
    const a = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 5, unit_cost: 60 }], null, "INV-3", null, 0, 0, null, null, null, ref]);
    const b = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 5, unit_cost: 60 }], null, "INV-3", null, 0, 0, null, null, null, ref]);
    expect(b.repeat).toBe(true);
    expect(b.number).toBe(a.number);
    expect(await stockOf(w, rice)).toBe(before + 5);
  });

  it("two people saving receipts at the same moment get different numbers and nothing is lost", async () => {
    const before = await stockOf(w, oil);
    const rs = await Promise.all([1, 2, 3, 4].map(() => rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: oil, qty: 1, unit_cost: 150 }], null, null, null, 0, 0, null, null, null, uuid()])));
    expect(new Set(rs.map((r: any) => r.number)).size).toBe(4);
    expect(await stockOf(w, oil)).toBe(before + 4);
  });

  it("a future bill date, negative tax or a stranger's supplier is refused", async () => {
    await expectError(rpc(w.manager.auth, "receive_goods", [sup, lines(1, 1), null, null, "2999-01-01", 0, 0, null, null, null, uuid()]), /future/i);
    await expectError(rpc(w.manager.auth, "receive_goods", [sup, lines(1, 1), null, null, null, -5, 0, null, null, null, uuid()]), /negative/i);
    await expectError(rpc(w.manager.auth, "receive_goods", [uuid(), lines(1, 1), null, null, null, 0, 0, null, null, null, uuid()]), /supplier/i);
  });

  it("tax and other charges are part of what is owed", async () => {
    const r = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 10, unit_cost: 60 }], null, "INV-T", null, 30, 20, null, null, null, uuid()]);
    expect(cents(r.total)).toBe(cents(600 + 30 + 20));
    const g = await grn(r.id);
    expect(g.payment_status).toBe("unpaid");
    expect(cents(g.subtotal)).toBe(60000);
  });

  it("paying the supplier from the till takes cash out of the open drawer and shows in the shift's expected cash", async () => {
    const r = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 10, unit_cost: 50 }], null, "INV-P", null, 0, 0, null, null, null, uuid()]);
    const ref = uuid();
    const p1 = await rpc(w.manager.auth, "pay_supplier", [r.id, 200, "cash", null, null, true, ref]);
    expect(cents(p1.balance)).toBe(30000);
    const again = await rpc(w.manager.auth, "pay_supplier", [r.id, 200, "cash", null, null, true, ref]);
    expect(again.repeat, "a retry does not pay twice").toBe(true);
    expect((await grn(r.id)).payment_status).toBe("partial");
    expect(cents((await grn(r.id)).paid_total)).toBe(20000);
    const mv = await admin("select direction, amount from public.cash_movements where shift_id = $1 and reason like 'Paid supplier%' ", [shift]);
    expect(mv.map((m) => [m.direction, cents(m.amount)])).toEqual([["out", 20000]]);
    await expectError(rpc(w.manager.auth, "pay_supplier", [r.id, 400, "cash", null, null, false, uuid()]), /still owed/i);
    await expectError(rpc(w.manager.auth, "pay_supplier", [r.id, 10, "bitcoin", null, null, false, uuid()]), /how the supplier/i);
    await expectError(rpc(w.manager.auth, "pay_supplier", [r.id, 10, "upi", null, null, true, uuid()]), /Only a cash payment/i);
    await expectError(rpc(w.manager.auth, "pay_supplier", [r.id, 0, "cash", null, null, false, uuid()]), /greater than zero/i);
    const p2 = await rpc(w.manager.auth, "pay_supplier", [r.id, 300, "bank", "UTR9", null, false, uuid()]);
    expect(p2.paid).toBe(true);
    expect((await grn(r.id)).payment_status).toBe("paid");
    await expectError(rpc(w.manager.auth, "pay_supplier", [r.id, 1, "cash", null, null, false, uuid()]), /fully paid/i);
  });

  it("one request reference cannot be reused to pay a different receipt", async () => {
    const a = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 1, unit_cost: 10 }], null, null, null, 0, 0, null, null, null, uuid()]);
    const b = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 1, unit_cost: 10 }], null, null, null, 0, 0, null, null, null, uuid()]);
    const ref = uuid();
    await rpc(w.manager.auth, "pay_supplier", [a.id, 5, "bank", null, null, false, ref]);
    await expectError(rpc(w.manager.auth, "pay_supplier", [b.id, 5, "bank", null, null, false, ref]), /already used/i);
  });

  it("undoing a till payment puts the cash back; the undo cannot be undone; a receipt with a payment cannot be cancelled until it is undone", async () => {
    const r = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: oil, qty: 2, unit_cost: 100 }], null, "INV-U", null, 0, 0, null, null, null, uuid()]);
    await rpc(w.manager.auth, "pay_supplier", [r.id, 200, "cash", null, null, true, uuid()]);
    const [{ id: payId }] = await admin("select id from public.supplier_payments where goods_receipt_id = $1 and reverses_id is null", [r.id]);
    await expectError(rpc(w.manager.auth, "cancel_goods_receipt", [r.id, "wrong delivery"]), /Undo the payment first/i);
    await expectError(rpc(w.manager.auth, "undo_supplier_payment", [payId, "x"]), /reason/i);
    const u = await rpc(w.manager.auth, "undo_supplier_payment", [payId, "paid the wrong bill"]);
    expect(cents(u.balance)).toBe(20000);
    expect((await grn(r.id)).payment_status).toBe("unpaid");
    const back = await admin("select direction, amount from public.cash_movements where shift_id = $1 and reason like 'Supplier payment undone%'", [shift]);
    expect(back.map((m) => [m.direction, cents(m.amount)])).toEqual([["in", 20000]]);
    await expectError(rpc(w.manager.auth, "undo_supplier_payment", [payId, "again"]), /already been undone/i);
    const [{ id: undoId }] = await admin("select id from public.supplier_payments where reverses_id = $1", [payId]);
    await expectError(rpc(w.manager.auth, "undo_supplier_payment", [undoId, "undo the undo"]), /itself an undo/i);
  });

  it("cancelling a receipt takes the goods back out of stock and restores the old cost", async () => {
    const [{ cost_per_unit: costBefore }] = await admin("select cost_per_unit from public.ingredients where id = $1", [oil]);
    const stockBefore = await stockOf(w, oil);
    const r = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: oil, qty: 10, unit_cost: 400 }], null, "INV-C", null, 0, 0, null, null, null, uuid()]);
    expect(await stockOf(w, oil)).toBe(stockBefore + 10);
    const c = await rpc(w.manager.auth, "cancel_goods_receipt", [r.id, "sent back, wrong goods"]);
    expect(c.cost_not_restored).toEqual([]);
    expect(await stockOf(w, oil)).toBe(stockBefore);
    const [{ cost_per_unit: costAfter }] = await admin("select cost_per_unit from public.ingredients where id = $1", [oil]);
    expect(Number(costAfter)).toBe(Number(costBefore));
    await expectError(rpc(w.manager.auth, "cancel_goods_receipt", [r.id, "again"]), /already cancelled/i);
    await expectError(rpc(w.manager.auth, "pay_supplier", [r.id, 1, "bank", null, null, false, uuid()]), /cancelled/i);
  });

  it("cancelling a receipt that came from an order reopens the order", async () => {
    const o = await rpc(w.manager.auth, "save_purchase_order", [null, sup, [{ ingredient_id: rice, qty: 3, unit_cost: 60 }], null, "", true]);
    const r = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 3, unit_cost: 60 }], o.id, null, null, 0, 0, null, null, null, uuid()]);
    expect((await admin("select status from public.purchase_orders where id = $1", [o.id]))[0].status).toBe("received");
    await rpc(w.manager.auth, "cancel_goods_receipt", [r.id, "bad batch"]);
    expect((await admin("select status from public.purchase_orders where id = $1", [o.id]))[0].status).toBe("ordered");
  });

  it("stock can go negative after cancelling a receipt whose goods were already used (the screen must show it)", async () => {
    const id = await rpc(w.manager.auth, "save_ingredient", [null, "Paneer", "kg", 300, 0, ""]);
    const r = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: id, qty: 5, unit_cost: 300 }], null, null, null, 0, 0, null, null, null, uuid()]);
    await rpc(w.manager.auth, "record_stock", [id, "wastage", 4, null, "used up"]);
    await rpc(w.manager.auth, "cancel_goods_receipt", [r.id, "returned to supplier"]);
    expect(await stockOf(w, id)).toBe(-4);
  });

  it("a stranger cannot read, pay or cancel another restaurant's receipt", async () => {
    const other = await makeWorld("purB");
    await admin("update public.restaurants set edition = 'professional' where id = $1", [other.restaurantId]);
    const r = await rpc(w.manager.auth, "receive_goods", [sup, [{ ingredient_id: rice, qty: 1, unit_cost: 10 }], null, null, null, 0, 0, null, null, null, uuid()]);
    await expectError(rpc(other.owner.auth, "pay_supplier", [r.id, 5, "cash", null, null, false, uuid()]), /not found/i);
    await expectError(rpc(other.owner.auth, "cancel_goods_receipt", [r.id, "attack"]), /not found/i);
  });
});
