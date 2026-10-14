import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright-core";
import type { Person, World } from "../../e2e/support/world";
import { PASSWORD } from "../../e2e/support/world";

export const baseUrl = () => process.env.UI_BASE_URL!;
export const haveUi = () => !!process.env.UI_BASE_URL;

function chromePath(): string {
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH ?? "/opt/pw-browsers";
  const dirs = existsSync(root) ? readdirSync(root).filter((d) => d.startsWith("chromium-")).sort() : [];
  for (const d of dirs.reverse()) for (const rel of ["chrome-linux/chrome", "chrome-linux64/chrome"]) { const p = join(root, d, rel); if (existsSync(p)) return p; }
  throw new Error("Chromium not found (set PLAYWRIGHT_BROWSERS_PATH)");
}

let browser: Browser | null = null;
export async function launch() {
  browser ??= await chromium.launch({ executablePath: chromePath(), args: ["--no-sandbox", "--no-proxy-server"] });
  return browser;
}
export async function closeBrowser() { await browser?.close(); browser = null; }

/** A fresh browser profile (its own cookies and storage), like a different till. */
export async function newContext(): Promise<BrowserContext> {
  return (await launch()).newContext({ baseURL: baseUrl(), viewport: { width: 1280, height: 900 } });
}

/** Signs in through the real login page, the way a cashier does: client code, staff code, password. */
export async function signIn(page: Page, w: World, who: Person) {
  await page.goto("/login");
  await page.locator('input[name="clientCode"]').fill(w.clientCode);
  await page.locator('input[name="username"]').fill(who.code);
  await page.locator('input[name="password"]').first().fill(PASSWORD);
  await Promise.all([page.waitForURL(/\/dashboard|\/pos|\/setup|\/shift|\/welcome/, { timeout: 60000 }), page.locator('button[name="intent"]').first().click()]);
}

/** The menu tile for a dish (not the same dish inside the cart, which has other buttons). */
export const tile = (page: Page, name: string) => page.locator("button").filter({ hasText: new RegExp(`^${name}\\s*₹`) });

export async function openPos(page: Page) {
  await page.goto("/pos");
  await page.waitForLoadState("networkidle").catch(() => {});
}

/** Text of the billing cart, e.g. to read Subtotal / Total as the cashier sees them. */
export async function cartText(page: Page) {
  const t = await page.locator("body").innerText();
  return (t.split("Current bill")[1] ?? "").replace(/\s+/g, " ").trim();
}
export const rupees = (s: string, label: string) => {
  const m = new RegExp(`${label}\\s*[+−-]?₹([\\d,]+\\.\\d\\d)`).exec(s);
  return m ? Math.round(Number(m[1].replace(/,/g, "")) * 100) : NaN;
};

/** Failed database requests (status 400 and up) recorded by the test gateway since `mark()`. */
import { existsSync as _exists, readFileSync as _read } from "node:fs";
export function restErrors(sinceMs: number): { status: number; method: string; path: string; error: string }[] {
  const f = process.env.UI_REST_LOG;
  if (!f || !_exists(f)) return [];
  return _read(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((e) => e.at >= sinceMs);
}
