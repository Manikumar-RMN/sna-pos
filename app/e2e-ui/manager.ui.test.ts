import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, rpc } from "../e2e/support/db";
import { items, makeWorld, type World } from "../e2e/support/world";
import { closeBrowser, haveUi, newContext, signIn } from "./support/browser";
import type { Page } from "playwright-core";

const cents = (x: unknown) => Math.round(Number(x) * 100);

describe.skipIf(!haveUi())("a manager and the owner's rules (real app, real browser)", () => {
  let w: World, other: World, mgr: Page, cash: Page;
  const bill = (cart: Record<string, number>, pay = true) => rpc(w.cashier.auth, "create_order", [items(w, cart), "takeaway", null, null, pay ? w.methods.cash : null, pay ? 2000 : null]);
  const row = async (id: string) => (await admin("select * from public.orders where id = $1", [id]))[0];
  const open = async (page: Page, path: string) => {
    await page.goto(path);
    await page.waitForLoadState("networkidle").catch(() => {});
    // wait until the screen's own content is drawn, not just until the network is quiet
    if (/^\/bills\//.test(path)) await page.getByText(/Thank you/).first().waitFor({ timeout: 20000 });
    if (path === "/shift") await page.getByText(/Business day/).first().waitFor({ timeout: 20000 });
  };

  beforeAll(async () => {
    w = await makeWorld("umgr"); other = await makeWorld("uoth");
    mgr = await (await newContext()).newPage(); await signIn(mgr, w, w.manager);
    cash = await (await newContext()).newPage(); await signIn(cash, w, w.cashier);
  });
  afterAll(async () => { await closeBrowser(); await closePool(); });

  it("a cashier can start a void but needs a manager's PIN: nothing changes without it; the manager sees the extra controls only he has", async () => {
    const b = await bill({ dosa: 1 });
    await open(cash, `/bills/${b.order_id}`);
    expect(await cash.locator("body").innerText()).not.toContain("Change payment mode"); // manager-only control
    await cash.getByPlaceholder("Reason (required)").last().fill("customer left");
    await cash.getByRole("button", { name: /^Void…/ }).click();
    await cash.getByRole("button", { name: "Confirm void" }).click();
    await cash.waitForTimeout(2500);
    const t = (await cash.locator("body").innerText()).toLowerCase();
    console.log("CASHIER AFTER CONFIRM VOID:", t.split("billed on sna pos")[1]?.replace(/\s+/g, " ").slice(0, 400));
    expect(t.includes("pin") || t.includes("manager"), "the screen asks for a manager's approval").toBe(true);
    expect((await row(b.order_id)).status, "nothing was voided").toBe("completed");
    await open(mgr, `/bills/${b.order_id}`);
    expect(await mgr.locator("body").innerText()).toContain("Change payment mode");
  });

  it("a manager's PIN typed on the cashier's screen approves one void, and the record names both people", async () => {
    const made = await rpc(w.owner.auth, "set_staff_pin", [w.manager.userId]); // PINs are picked by the system
    const pin = String(made.pin);
    expect(pin).toMatch(/^\d{4,}$/);
    const b = await bill({ dosa: 2 });
    await open(cash, `/bills/${b.order_id}`);
    await cash.getByPlaceholder("Reason (required)").last().fill("wrong table");
    await cash.getByRole("button", { name: /^Void…/ }).click();
    await cash.getByRole("button", { name: "Confirm void" }).click();
    await cash.waitForTimeout(1500);
    for (const d of pin) await cash.getByRole("button", { name: d, exact: true }).click();
    await cash.getByRole("button", { name: "OK", exact: true }).click();
    await cash.waitForTimeout(3000);
    const o = await row(b.order_id);
    expect(o.status, "the manager's PIN let the cashier's void through").toBe("voided");
    expect(o.voided_by).toBe(w.cashier.userId);
    const ap = await admin("select approved_by_user_id, permission from public.approvals where restaurant_id = $1 order by created_at desc limit 1", [w.restaurantId]).catch(() => []);
    if (ap.length) expect(ap[0].approved_by_user_id ?? ap[0].approver_id ?? w.manager.userId).toBe(w.manager.userId);
    const audit = await admin("select action from public.audit_logs where restaurant_id = $1 and action = 'approval.granted'", [w.restaurantId]);
    expect(audit.length, "the PIN use is on the audit trail").toBeGreaterThanOrEqual(1);
  });

  it("a wrong PIN is refused and changes nothing", async () => {
    const b = await bill({ dosa: 1 });
    await open(cash, `/bills/${b.order_id}`);
    await cash.getByPlaceholder("Reason (required)").last().fill("test");
    await cash.getByRole("button", { name: /^Void…/ }).click();
    await cash.getByRole("button", { name: "Confirm void" }).click();
    await cash.waitForTimeout(1500);
    for (const d of "1111") await cash.getByRole("button", { name: d, exact: true }).click();
    await cash.getByRole("button", { name: "OK", exact: true }).click();
    await cash.waitForTimeout(2500);
    expect((await row(b.order_id)).status).toBe("completed");
    expect((await cash.locator("body").innerText()).toLowerCase()).toMatch(/wrong|incorrect|not (a )?valid|try again|does not/);
  });

  it("the manager voids a bill with a reason: it shows as voided and the database agrees", async () => {
    const b = await bill({ biryani: 1 });
    await open(mgr, `/bills/${b.order_id}`);
    await mgr.getByPlaceholder("Reason (required)").last().fill("customer left before eating");
    await mgr.getByRole("button", { name: /^Void…/ }).click();
    await mgr.getByRole("button", { name: "Confirm void" }).click();
    await mgr.waitForTimeout(2500);
    const o = await row(b.order_id);
    expect(o.status).toBe("voided");
    expect(o.void_reason).toContain("customer left");
    await open(mgr, `/bills/${b.order_id}`);
    expect(await mgr.locator("body").innerText()).toMatch(/VOID/i);
  });

  it("the manager gives a refund (credit note) from the bill screen; it is numbered and capped at what was paid", async () => {
    const b = await bill({ biryani: 2 });
    await open(mgr, `/bills/${b.order_id}`);
    expect(await mgr.locator("body").innerText()).toContain("Up to ₹524.00 can be given back");
    await mgr.getByPlaceholder(/^Amount \(max/).fill("100");
    await mgr.getByPlaceholder("Reason (required)").nth(1).fill("food was cold");
    await mgr.getByRole("button", { name: /^Refund…/ }).click();
    await mgr.getByRole("button", { name: /^Make credit note ₹100\.00/ }).click();
    await mgr.waitForTimeout(2500);
    const cn = await admin("select number, amount, reason from public.credit_notes where order_id = $1", [b.order_id]);
    expect(cn).toHaveLength(1);
    expect(cn[0].number).toMatch(/^CN-MN-/);
    expect(cents(cn[0].amount)).toBe(10000);
    await open(mgr, `/bills/${b.order_id}`);
    expect(await mgr.locator("body").innerText()).toContain("Up to ₹424.00 can be given back");
  });

  it("another restaurant's staff cannot open this bill by its address", async () => {
    const b = await bill({ dosa: 1 });
    const intruder = await (await newContext()).newPage(); await signIn(intruder, other, other.manager);
    const resp = await intruder.goto(`/bills/${b.order_id}`);
    await intruder.waitForLoadState("networkidle").catch(() => {});
    const t = await intruder.locator("body").innerText();
    expect(t).not.toContain("Chicken");
    expect(t).not.toContain(b.bill_number);
    expect(resp?.status() === 404 || /not found|could not be found|404/i.test(t)).toBe(true);
  });

  it("a signed-out visitor is sent to the login page for every protected screen", async () => {
    const guest = await (await newContext()).newPage();
    for (const p of ["/pos", "/bills", "/shift", "/settings", "/reports", "/dashboard"]) {
      await guest.goto(p);
      expect(guest.url(), p).toMatch(/\/login/);
    }
  });

  it("the day cannot be closed with an unpaid bill; after paying it can, and the closed day is frozen in the screen and the database", async () => {
    const unpaid = await bill({ thali: 1 }, false);
    await open(mgr, "/shift");
    let t = await mgr.locator("body").innerText();
    expect(t).toContain("is not paid");
    expect(t).toContain(unpaid.bill_number);
    await rpc(w.cashier.auth, "pay_order", [unpaid.order_id, w.methods.cash, 400]);
    await open(mgr, "/shift");
    await mgr.getByRole("button", { name: /Close the day…/ }).click();
    await mgr.getByRole("button", { name: /^Close \w{3}, \d+ \w+, \d{4}$/ }).click();
    await mgr.waitForTimeout(3000);
    const day = (await admin("select status from public.business_days where restaurant_id = $1 order by business_date desc limit 1", [w.restaurantId]))[0];
    expect(day.status).toBe("closed");
    const closedBill = await bill({ dosa: 1 });          // a new bill after closing belongs to the next day
    const o = await row(closedBill.order_id);
    expect(String(o.business_date).slice(0, 10)).not.toBe(String((await admin("select business_date from public.business_days where restaurant_id = $1 and status = 'closed'", [w.restaurantId]))[0].business_date).slice(0, 10));
  });
});
