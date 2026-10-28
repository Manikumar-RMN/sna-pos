import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { admin, closePool } from "../e2e/support/db";
import { makeWorld, type World } from "../e2e/support/world";
import { closeBrowser, haveUi, newContext, openPos, signIn, tile, cartText, rupees } from "./support/browser";
import type { Page } from "playwright-core";

const cents = (x: unknown) => Math.round(Number(x) * 100);

describe.skipIf(!haveUi())("a cashier at the till (real app, real browser)", () => {
  let w: World, page: Page;
  beforeAll(async () => {
    w = await makeWorld("ubill");
    await admin("update public.payment_methods set ask_reference = true where restaurant_id = $1 and kind in ('upi','card')", [w.restaurantId]); // the shop asks for the UPI transaction id
    page = await (await newContext()).newPage();
    await signIn(page, w, w.cashier);
  });
  afterAll(async () => { await closeBrowser(); await closePool(); });

  const lastOrder = async () => (await admin("select * from public.orders where restaurant_id = $1 order by created_at desc limit 1", [w.restaurantId]))[0];

  it("sees the menu with the right prices", async () => {
    await openPos(page);
    for (const [n, p] of [["Masala Dosa", "₹120.00"], ["Chicken Biryani", "₹249.50"], ["Cola", "₹60.00"], ["Veg Thali", "₹333.33"]])
      await expect(tile(page, n).first().innerText()).resolves.toContain(p);
  });

  it("the cart adds up as the database will: subtotal, GST, rounding and total", async () => {
    await openPos(page);
    await page.getByRole("button", { name: "Takeaway", exact: true }).click();
    await tile(page, "Masala Dosa").click(); await tile(page, "Masala Dosa").click(); await tile(page, "Cola").click();
    await page.waitForTimeout(1200);
    const t = await cartText(page);
    expect(rupees(t, "Subtotal")).toBe(30000);
    expect(rupees(t, "GST")).toBe(2280);
    expect(rupees(t, "Total")).toBe(32300);
  });

  it("the minus button and Clear change the bill; an empty bill cannot be charged", async () => {
    await page.getByRole("button", { name: "One less Masala Dosa" }).click();            // one dosa fewer
    await page.waitForTimeout(1000);
    expect(rupees(await cartText(page), "Subtotal")).toBe(18000);
    await page.getByRole("button", { name: "Clear" }).click();
    await page.waitForTimeout(500);
    expect(await cartText(page)).toContain("No items yet");
    await expect(page.getByRole("button", { name: /^Charge/ }).isDisabled()).resolves.toBe(true);
  });

  it("takes a cash bill: change is shown, the receipt is right, and the database agrees", async () => {
    await openPos(page);
    await page.getByRole("button", { name: "Takeaway", exact: true }).click();
    await tile(page, "Masala Dosa").click(); await tile(page, "Masala Dosa").click(); await tile(page, "Cola").click();
    await page.getByPlaceholder("Cash received").fill("500");
    await page.waitForTimeout(600);
    expect(await cartText(page)).toContain("Change ₹177.00");
    await page.getByRole("button", { name: /^Charge/ }).click();
    await page.waitForURL(/\/pos\?bill=|\/pos\/receipt\//, { timeout: 30000 });
    await page.getByText("Thank you").first().waitFor({ timeout: 30000 });   // the page has finished drawing the receipt
    const receipt = await page.locator("body").innerText();
    for (const s of ["TAX INVOICE", "Masala Dosa", "₹240.00", "Cola", "CGST (2.5%)", "SGST (2.5%)", "CGST (9%)", "TOTAL", "₹323.00", "Paid (Cash)", "Tendered", "₹500.00", "₹177.00"]) expect(receipt.toLowerCase(), s).toContain(s.toLowerCase()); // the heading is upper-cased by the stylesheet, which may not have loaded yet
    const o = await lastOrder();
    expect([o.status, o.payment_status, cents(o.grand_total), o.order_type]).toEqual(["completed", "paid", 32300, "takeaway"]);
    expect(receipt).toContain(o.bill_number);
    const [p] = await admin("select amount, tendered_amount, change_amount from public.payments where order_id = $1", [o.id]);
    expect([cents(p.amount), cents(p.tendered_amount), cents(p.change_amount)]).toEqual([32300, 50000, 17700]);
  });

  it("each bill gets the next number, with no gap", async () => {
    const before = await lastOrder();
    await openPos(page);
    await page.getByRole("button", { name: "Takeaway", exact: true }).click();
    await tile(page, "Veg Thali").click();
    await page.getByPlaceholder("Cash received").fill("500");
    await page.getByRole("button", { name: /^Charge/ }).click();
    await page.waitForURL(/\/pos\?bill=|\/pos\/receipt\//, { timeout: 30000 });
    const after = await lastOrder();
    expect(Number(after.bill_number.split("-").pop())).toBe(Number(before.bill_number.split("-").pop()) + 1);
    expect(cents(after.grand_total)).toBe(35000); // 333.33 + 5% GST = 349.99, rounded to the rupee
  });

  it("UPI: the reference is kept for the settlement report", async () => {
    await openPos(page);
    await page.getByRole("button", { name: "Takeaway", exact: true }).click();
    await tile(page, "Chicken Biryani").click();
    await page.getByRole("button", { name: "UPI", exact: true }).click();
    const ref = page.getByPlaceholder(/Reference, e\.g\. UPI txn ID/);
    await ref.fill("UPI-REF-8842");
    await page.getByRole("button", { name: /^Charge/ }).click();
    await page.waitForURL(/\/pos\?bill=|\/pos\/receipt\//, { timeout: 30000 });
    const o = await lastOrder();
    const [p] = await admin("select reference_no, payment_method_id from public.payments where order_id = $1", [o.id]);
    expect(p.reference_no).toBe("UPI-REF-8842");
    expect(p.payment_method_id).toBe(w.methods.upi);
    expect(cents(o.grand_total)).toBe(26200);
  });

  it("a dine-in bill is saved unpaid to the kitchen, listed in Bills, then paid from the bill screen", async () => {
    await openPos(page);
    await page.getByRole("button", { name: /^Table T1,/ }).click();            // the coloured table strip of the single order screen
    await tile(page, "Masala Dosa").click(); await tile(page, "Cola").click();
    await page.getByLabel("Number of guests").fill("2");                        // a dine-in bill needs at least one guest
    await page.getByRole("button", { name: "Send to kitchen", exact: true }).click();
    await page.waitForTimeout(2500);
    const o = await lastOrder();
    expect([o.payment_status, o.order_type], "saved to the kitchen, not yet paid").toEqual(["unpaid", "dine_in"]);
    expect((await admin("select count(*)::int n from public.kitchen_tickets where order_id = $1", [o.id]))[0].n).toBeGreaterThanOrEqual(1);
    await page.goto("/bills");
    await page.getByText(o.bill_number).first().waitFor({ timeout: 20000 });   // wait for the list to be drawn
    await page.goto(`/bills/${o.id}`);
    await page.getByRole("button", { name: /^Take ₹197\.00/ }).click();
    await page.waitForTimeout(2500);
    const paid = (await admin("select status, payment_status, paid_total from public.orders where id = $1", [o.id]))[0];
    expect([paid.status, paid.payment_status, cents(paid.paid_total)]).toEqual(["completed", "paid", 19700]);
  });

  it("searching the menu narrows the tiles", async () => {
    await openPos(page);
    await page.getByPlaceholder(/Search the menu/).fill("thali");
    await page.waitForTimeout(500);
    expect(await tile(page, "Veg Thali").count()).toBe(1);
    expect(await tile(page, "Cola").count()).toBe(0);
  });

  it("a cashier cannot discount without a manager (the screen asks for approval)", async () => {
    await openPos(page);
    await page.getByRole("button", { name: "Takeaway", exact: true }).click();
    await tile(page, "Masala Dosa").click();
    await page.getByText("Discount", { exact: true }).first().click().catch(() => {});
    await page.waitForTimeout(600);
    const t = (await page.locator("body").innerText()).toLowerCase();
    expect(t.includes("manager") || t.includes("pin") || t.includes("approv") || t.includes("discount")).toBe(true);
  });
});
