import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, rpc } from "../e2e/support/db";
import { items, makeWorld, type World } from "../e2e/support/world";
import { closeBrowser, haveUi, newContext, signIn } from "./support/browser";
import type { Page } from "playwright-core";

describe.skipIf(!haveUi())("Settings -> Company: the client sets the time zone and the screens follow it (real app, real browser)", () => {
  let w: World, page: Page, cashierPage: Page;
  beforeAll(async () => {
    w = await makeWorld("utz");
    page = await (await newContext()).newPage();
    await signIn(page, w, w.owner);
    cashierPage = await (await newContext()).newPage();
    await signIn(cashierPage, w, w.cashier);
  });
  afterAll(async () => { await closeBrowser(); await closePool(); });

  it("the owner sees the Time zone card, with the current zone chosen", async () => {
    await page.goto("/settings/company", { waitUntil: "domcontentloaded" });
    await page.getByRole("heading", { name: "Time zone" }).waitFor();
    const select = page.locator("select").filter({ has: page.locator("option[value='Asia/Dubai']") }).first();
    const [{ timezone }] = await admin("select timezone from public.restaurants where id = $1", [w.restaurantId]);
    expect(await select.inputValue()).toBe(timezone);
  });

  it("changing it saves it for the restaurant and every outlet", async () => {
    const select = page.locator("select").filter({ has: page.locator("option[value='Asia/Dubai']") }).first();
    await select.selectOption("Asia/Dubai");
    await page.getByRole("button", { name: "Save time zone" }).click();
    await page.getByText("Time zone saved").waitFor();
    const rows = await admin("select distinct timezone from public.restaurants where id = $1 union select distinct timezone from public.branches where restaurant_id = $1", [w.restaurantId]);
    expect(rows.map((r) => r.timezone)).toEqual(["Asia/Dubai"]);
  });

  it("the bills screen then shows the bill's time on Dubai's clock", async () => {
    await rpc(w.cashier.auth, "open_shift", [0]);
    const bill = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 1 }), "takeaway", null, null, w.methods.cash, 500]);
    const [{ created_at }] = await admin("select created_at from public.orders where id = $1", [bill.order_id]);
    const expected = new Intl.DateTimeFormat("en-IN", { timeZone: "Asia/Dubai", hour: "2-digit", minute: "2-digit" }).format(new Date(created_at));
    await page.goto(`/bills/${bill.order_id}`, { waitUntil: "domcontentloaded" });
    await page.waitForLoadState("networkidle", { timeout: 15000 }).catch(() => {});
    const text = (await page.locator("body").innerText()).toLowerCase();
    expect(text).toContain(expected.toLowerCase());
  });

  it("a shift that is open blocks the change, with words", async () => {
    await page.goto("/settings/company", { waitUntil: "domcontentloaded" });
    const select = page.locator("select").filter({ has: page.locator("option[value='Asia/Dubai']") }).first();
    await select.selectOption("Asia/Singapore");
    await page.getByRole("button", { name: "Save time zone" }).click();
    await page.getByText(/Close the open shift/).waitFor();
    const [{ timezone }] = await admin("select timezone from public.restaurants where id = $1", [w.restaurantId]);
    expect(timezone).toBe("Asia/Dubai");
  });

  it("a cashier cannot open the Company settings", async () => {
    await cashierPage.goto("/settings/company", { waitUntil: "domcontentloaded" });
    expect(await cashierPage.getByRole("heading", { name: "Time zone" }).count()).toBe(0);
  });
});
