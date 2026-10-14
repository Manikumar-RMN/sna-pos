import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool } from "../e2e/support/db";
import { makeWorld, type World } from "../e2e/support/world";
import { closeBrowser, haveUi, newContext, openPos, signIn, tile } from "./support/browser";
import type { BrowserContext, Page } from "playwright-core";

const cents = (x: unknown) => Math.round(Number(x) * 100);
const Q = "sna.offline.queue.v1", STUCK = "sna.offline.stuck.v1";

describe.skipIf(!haveUi())("the till with no internet (real app, real browser)", () => {
  let w: World, ctx: BrowserContext, page: Page, mgr: Page;
  const orders = () => admin("select * from public.orders where restaurant_id = $1 order by created_at", [w.restaurantId]);
  const waitForOrders = async (n: number, ms = 60000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if ((await orders()).length >= n) return; await new Promise((r) => setTimeout(r, 500)); } throw new Error(`only ${(await orders()).length} orders reached the server (wanted ${n})`); };
  const queue = () => page.evaluate((k) => JSON.parse(localStorage.getItem(k) ?? "[]"), Q) as Promise<any[]>;
  const editQueue = (fn: string) => page.evaluate(([k, code]) => { const q = JSON.parse(localStorage.getItem(k) ?? "[]"); (new Function("q", code))(q); localStorage.setItem(k, JSON.stringify(q)); }, [Q, fn] as const);
  const ring = async (items: string[], cash = "500") => {
    await openPosIfNeeded();
    await page.getByRole("button", { name: "Takeaway", exact: true }).click();
    for (const i of items) await tile(page, i).click();
    await page.getByPlaceholder("Cash received").fill(cash);
    await page.getByRole("button", { name: /^Charge/ }).click();
    await page.getByText(/Saved offline on this device/).waitFor({ timeout: 15000 });
    await page.getByRole("button", { name: "Next bill", exact: true }).click();
  };
  const openPosIfNeeded = async () => { if (!/\/pos$/.test(page.url())) await page.goto("/pos", { waitUntil: "domcontentloaded" }).catch(() => {}); await page.getByText("Tap an item to add it").waitFor({ timeout: 20000 }); };

  beforeAll(async () => {
    w = await makeWorld("uoff");
    await admin("insert into public.restaurant_modules (restaurant_id, module_key) values ($1, 'owner_app') on conflict do nothing", [w.restaurantId]);
    ctx = await newContext(); page = await ctx.newPage();
    await signIn(page, w, w.cashier); await openPos(page);
    await page.waitForFunction(() => !!localStorage.getItem("sna.offline.snapshot.v1"), null, { timeout: 30000 });   // the till copied the menu
    mgr = await (await newContext()).newPage(); await signIn(mgr, w, w.manager);
  });
  afterAll(async () => { await closeBrowser(); await closePool(); });

  it("with no internet it says so, keeps billing paid bills, and queues them with their own numbers", async () => {
    await ctx.setOffline(true);
    await page.waitForTimeout(1200);
    expect(await page.locator("body").innerText()).toMatch(/No internet/);
    await ring(["Masala Dosa", "Cola"]);
    const q = await queue();
    expect(q).toHaveLength(1);
    expect(q[0].number).toBe("MN26-X1-0001");
    expect(cents(q[0].grand_total)).toBe(19700);
    expect(q[0].snapshot_at, "the till says when its menu copy was taken").toBeTruthy();
    expect(await page.locator("body").innerText()).toMatch(/1 offline bill waiting/);
    expect(await orders()).toHaveLength(0);
  });

  it("when the internet returns the bill is sent by itself, recorded exactly as made, and the queue empties", async () => {
    await ctx.setOffline(false);
    await waitForOrders(1);
    const [o] = await orders();
    expect([o.bill_number, o.status, o.payment_status, cents(o.grand_total)]).toEqual(["MN26-X1-0001", "completed", "paid", 19700]);
    expect(o.offline_flags).toBeNull();
    await page.waitForFunction((k) => JSON.parse(localStorage.getItem(k) ?? "[]").length === 0, Q, { timeout: 30000 });
    const [p] = await admin("select amount, tendered_amount, change_amount from public.payments where order_id = $1", [o.id]);
    expect([cents(p.amount), cents(p.tendered_amount), cents(p.change_amount)]).toEqual([19700, 50000, 30300]);
  });

  it("a till that has been tampered with (price edited on the device) is corrected, reported to the owner, and shown to the manager", async () => {
    await ctx.setOffline(true);
    await ring(["Masala Dosa", "Cola"]);
    await editQueue("q[0].items[0].price = 1; q[0].calc = null;");   // the dosa 'costs' 1.00 now
    await ctx.setOffline(false);
    await waitForOrders(2);
    const o = (await orders())[1];
    expect(cents(o.grand_total), "recorded at the real prices, not the edited one").toBe(19700);
    expect((o.offline_flags as any[]).map((f) => f.flag)).toContain("price_corrected");
    const alerts = await admin("select title, body from public.owner_alerts where restaurant_id = $1 and kind = 'order.offline_flagged'", [w.restaurantId]);
    expect(alerts.some((a) => a.body.includes(o.bill_number))).toBe(true);
    await mgr.goto(`/bills/${o.id}`); await mgr.waitForLoadState("networkidle").catch(() => {});
    const t = await mgr.locator("body").innerText();
    expect(t).toContain("This bill was made offline and needed a correction");
    expect(t).toContain("Masala Dosa");
    expect(t).toMatch(/charged 1\.00/);
    expect(t).toMatch(/real price, 120\.00/);
    // the cashier, who has no right to void, is not shown the correction notes
    await page.goto(`/bills/${o.id}`); await page.waitForLoadState("networkidle").catch(() => {});
    expect(await page.locator("body").innerText()).not.toContain("needed a correction");
  });

  it("a discount typed into the queued bill by someone without the right is not honoured", async () => {
    await page.goto("/pos", { waitUntil: "domcontentloaded" });
    await ctx.setOffline(true);
    await ring(["Chicken Biryani"], "600");
    await editQueue("q[0].discount = 100;");
    await ctx.setOffline(false);
    await waitForOrders(3);
    const o = (await orders())[2];
    expect(cents(o.grand_total)).toBe(26200);
    expect((o.offline_flags as any[]).map((f) => f.flag)).toContain("discount_removed");
  });

  it("one bill the server refuses does not stop the bills behind it; it is kept on the device, shown, and can be tried again", async () => {
    await page.goto("/pos", { waitUntil: "domcontentloaded" });
    await ctx.setOffline(true);
    await ring(["Veg Thali"], "500");
    await ring(["Cola"], "100");
    await editQueue("q[0].items[0].product_id = '00000000-0000-4000-8000-000000000001';");   // an item that no longer exists
    const before = (await orders()).length;
    await ctx.setOffline(false);
    await waitForOrders(before + 1);                                                           // the second bill gets through
    const after = await orders();
    expect(after[after.length - 1].bill_number).toMatch(/X1-000[56]$/);
    // the refused bill: tried again (Send now) until the device puts it aside
    for (let i = 0; i < 4; i++) { await page.getByRole("button", { name: "Send now" }).click().catch(() => {}); await page.waitForTimeout(1500); }
    await page.getByText(/could not be accepted by the server/).waitFor({ timeout: 30000 });
    const stuck = await page.evaluate((k) => JSON.parse(localStorage.getItem(k) ?? "[]"), STUCK) as any[];
    expect(stuck).toHaveLength(1);
    expect(stuck[0].sync_error).toMatch(/no longer exists/);
    expect(await queue()).toHaveLength(0);
    expect(await page.getByRole("button", { name: "Save a copy" }).count()).toBe(1);
    expect(await page.getByRole("button", { name: "Try again" }).count()).toBe(1);
  });
});
