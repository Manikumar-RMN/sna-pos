import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool, rpc } from "../e2e/support/db";
import { items, makeWorld, type World } from "../e2e/support/world";
import { closeBrowser, haveUi, newContext, restErrors, signIn } from "./support/browser";
import type { Page } from "playwright-core";

// Every screen of the restaurant app, opened as the owner (who may open all of them), with real data behind it.
const SCREENS = [
  "/dashboard", "/pos", "/bills", "/shift", "/kitchen", "/reports", "/owner", "/menu", "/stock", "/purchases", "/reservations", "/deliveries",
  "/preorders", "/accounts", "/loyalty", "/captain", "/table-orders", "/batches", "/online-orders", "/timesheets", "/help", "/ready", "/display",
  "/settings", "/settings/company", "/settings/bill", "/settings/taxes", "/settings/charges", "/settings/payments", "/settings/printers",
  "/settings/tables", "/settings/tables/qr", "/settings/users", "/settings/security", "/settings/day", "/settings/counters", "/settings/offers",
  "/settings/reports", "/settings/outlets", "/settings/brands", "/settings/plan", "/settings/api", "/settings/menu", "/account/password",
  // one-batch additions: the three new reports and the bulk price change screen
  "/reports/covers", "/reports/reprints", "/reports/tips", "/settings/menu/bulk-price",
];

describe.skipIf(!haveUi())("every screen opens without an error page or a refused database request (real app, real browser)", () => {
  let w: World, page: Page, paid: any;
  beforeAll(async () => {
    w = await makeWorld("uscr");
    await rpc(w.cashier.auth, "open_shift", [0]).catch(() => {});
    paid = await rpc(w.cashier.auth, "create_order", [items(w, { dosa: 2, cola: 1 }), "takeaway", null, null, w.methods.cash, 500]);
    await rpc(w.cashier.auth, "create_order", [items(w, { biryani: 1 }), "dine_in", w.tableId]);
    page = await (await newContext()).newPage();
    await signIn(page, w, w.owner);
  });
  afterAll(async () => { await closeBrowser(); await closePool(); });

  for (const path of SCREENS)
    it(path, async () => {
      const t0 = Date.now();
      const errors: string[] = [];
      const onErr = (e: Error) => errors.push(`page error: ${e.message.slice(0, 160)}`);
      page.on("pageerror", onErr);
      const resp = await page.goto(path, { waitUntil: "domcontentloaded" });
      await page.waitForLoadState("networkidle", { timeout: 15000 }).catch(() => {});
      page.off("pageerror", onErr);
      const body = await page.locator("body").innerText();
      expect(resp?.status(), `${path} HTTP status`).toBeLessThan(500);
      expect(page.url(), `${path} was not sent away`).toContain(path.split("/").slice(0, 2).join("/"));
      expect(body, `${path} shows an error page`).not.toMatch(/Application error|Something went wrong|Internal Server Error|This page couldn.t load|Unhandled Runtime Error/i);
      const refused = restErrors(t0).map((e) => `${e.status} ${e.method} ${e.path} -> ${e.error}`);
      expect([...errors, ...refused], `${path}: errors while it loaded`).toEqual([]);
    });

  it("the receipt and bill screens for a real bill", async () => {
    for (const p of [`/bills/${paid.order_id}`, `/pos/receipt/${paid.order_id}`, `/pos/kot/${paid.order_id}`]) {
      const t0 = Date.now();
      const resp = await page.goto(p, { waitUntil: "domcontentloaded" });
      await page.waitForLoadState("networkidle", { timeout: 15000 }).catch(() => {});
      expect(resp?.status(), p).toBeLessThan(500);
      expect(await page.locator("body").innerText(), p).not.toMatch(/Application error|Something went wrong|Internal Server Error/i);
      expect(restErrors(t0).map((e) => `${e.status} ${e.path} -> ${e.error}`), p).toEqual([]);
    }
    void admin;
  });
});
