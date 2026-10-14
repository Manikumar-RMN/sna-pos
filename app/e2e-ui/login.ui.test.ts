import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool } from "../e2e/support/db";
import { makeWorld, PASSWORD, type World } from "../e2e/support/world";
import { closeBrowser, haveUi, newContext } from "./support/browser";
import type { Page } from "playwright-core";

describe.skipIf(!haveUi())("signing in and out (real app, real browser)", () => {
  let w: World;
  beforeAll(async () => { w = await makeWorld("ulog"); });
  afterAll(async () => { await closeBrowser(); await closePool(); });

  const fill = async (page: Page, o: { code?: string; user?: string; pass?: string }) => {
    await page.goto("/login");
    await page.locator('input[name="clientCode"]').fill(o.code ?? w.clientCode);
    await page.locator('input[name="username"]').fill(o.user ?? w.cashier.code);
    await page.locator('input[name="password"]').first().fill(o.pass ?? PASSWORD);
    await page.locator('button[name="intent"]').first().click();
  };

  it("a wrong password, a wrong client code and an unknown staff code all get the same vague message", async () => {
    const page = await (await newContext()).newPage();
    for (const o of [{ pass: "wrong-password" }, { code: "9999" }, { user: "EMP999" }]) {
      await fill(page, o);
      await page.getByText("Invalid client code, username, or password.").waitFor({ timeout: 20000 });
      expect(page.url()).toMatch(/\/login/);
    }
  });

  it("the right details sign in to the dashboard; Sign out returns to login and the screens are closed again", async () => {
    const page = await (await newContext()).newPage();
    await fill(page, {});
    await page.waitForURL(/\/dashboard/, { timeout: 30000 });
    expect(await page.locator("body").innerText()).toContain(`Cashier ${w.tag}`);
    await page.goto("/login");
    expect(page.url(), "a signed-in person is sent on to the dashboard").toMatch(/\/dashboard/);
    await page.getByRole("button", { name: "Sign out" }).first().click();
    await page.waitForURL(/\/login/, { timeout: 30000 });
    await page.goto("/pos");
    expect(page.url()).toMatch(/\/login/);
  });

  it("five wrong passwords lock that staff member out for a few minutes, even with the right password", async () => {
    const page = await (await newContext()).newPage();
    for (let i = 0; i < 5; i++) { await fill(page, { user: w.manager.code, pass: `wrong-${i}` }); await page.getByText(/Invalid client code|Too many wrong passwords/).waitFor({ timeout: 20000 }); }
    await fill(page, { user: w.manager.code });
    await page.getByText(/Too many wrong passwords/).waitFor({ timeout: 20000 });
    expect(page.url()).toMatch(/\/login/);
    const [u] = await admin("select login_locked_until from public.users where id = $1", [w.manager.userId]);
    expect(new Date(u.login_locked_until).getTime()).toBeGreaterThan(Date.now());
  });

  it("a deactivated staff member cannot sign in", async () => {
    await admin("update public.users set is_active = false where id = $1", [w.cashier.userId]);
    const page = await (await newContext()).newPage();
    await fill(page, {});
    await page.getByText(/no longer active|Invalid client code/).waitFor({ timeout: 20000 });
    expect(page.url()).toMatch(/\/login/);
    await admin("update public.users set is_active = true where id = $1", [w.cashier.userId]);
  });
});
