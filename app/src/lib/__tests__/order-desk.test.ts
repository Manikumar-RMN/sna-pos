import { describe, expect, it } from "vitest";
import {
  DEFAULT_SCREEN,
  MAX_COVERS,
  coversError,
  deskUrl,
  discardQuestion,
  needsInternetText,
  openPriceError,
  openPriceValue,
  parseCovers,
  parseScreenMode,
  resolveDeskTarget,
} from "../order-desk";

const A = "0b6f7c1e-6a8e-4e0a-9d0e-1f2a3b4c5d6e";
const B = "9a1c2d3e-4f50-4a6b-8c7d-0e1f2a3b4c5d";

describe("screen mode", () => {
  it("the default is the one-screen layout (Founder decision) and it is a single constant", () => {
    expect(DEFAULT_SCREEN).toBe("one");
    expect(parseScreenMode(undefined)).toBe(DEFAULT_SCREEN);
    expect(parseScreenMode(null)).toBe(DEFAULT_SCREEN);
    expect(parseScreenMode("garbage")).toBe(DEFAULT_SCREEN);
  });
  it("a saved choice wins over the default", () => {
    expect(parseScreenMode("classic")).toBe("classic");
    expect(parseScreenMode("one")).toBe("one");
  });
});

describe("resolveDeskTarget", () => {
  it("no parameters = the counter", () => {
    expect(resolveDeskTarget({})).toEqual({ target: { kind: "counter" }, redirectTo: null });
  });
  it("?bill= selects a bill", () => {
    expect(resolveDeskTarget({ bill: A })).toEqual({ target: { kind: "bill", billId: A }, redirectTo: null });
  });
  it("?table= selects a table", () => {
    expect(resolveDeskTarget({ table: B })).toEqual({ target: { kind: "table", tableId: B }, redirectTo: null });
  });
  it("legacy ?add= is the same bill and asks for a redirect to the new address", () => {
    expect(resolveDeskTarget({ add: A })).toEqual({ target: { kind: "bill", billId: A }, redirectTo: `/pos?bill=${A}` });
  });
  it("bill wins over add and table; add wins over table", () => {
    expect(resolveDeskTarget({ bill: A, table: B, add: B }).target).toEqual({ kind: "bill", billId: A });
    expect(resolveDeskTarget({ add: A, table: B }).target).toEqual({ kind: "bill", billId: A });
  });
  it("something that is not an id is ignored, never trusted", () => {
    expect(resolveDeskTarget({ bill: "1; drop table", table: "x" })).toEqual({ target: { kind: "counter" }, redirectTo: null });
    expect(resolveDeskTarget({ bill: ["", A] }).target).toEqual({ kind: "counter" });
    expect(resolveDeskTarget({ bill: [A, B] }).target).toEqual({ kind: "bill", billId: A });
  });
});

describe("deskUrl", () => {
  it("builds the addresses the screen uses", () => {
    expect(deskUrl({ kind: "counter" })).toBe("/pos");
    expect(deskUrl({ kind: "table", tableId: B })).toBe(`/pos?table=${B}`);
    expect(deskUrl({ kind: "bill", billId: A })).toBe(`/pos?bill=${A}`);
    expect(deskUrl({ kind: "bill", billId: A }, { print: true })).toBe(`/pos?bill=${A}&print=1`);
    expect(deskUrl({ kind: "bill", billId: A }, { pay: "split" })).toBe(`/pos?bill=${A}&pay=split`);
  });
  it("round-trips through resolveDeskTarget", () => {
    const t = { kind: "bill", billId: A } as const;
    const url = new URL(deskUrl(t, { print: true }), "http://x");
    expect(resolveDeskTarget({ bill: url.searchParams.get("bill") ?? undefined }).target).toEqual(t);
  });
});

describe("guests (covers) rule", () => {
  it("parses whole numbers 1..99 only", () => {
    expect(parseCovers("1")).toBe(1);
    expect(parseCovers(" 12 ")).toBe(12);
    expect(parseCovers(String(MAX_COVERS))).toBe(MAX_COVERS);
    for (const bad of ["", "0", "00", "-1", "1.5", "100", "abc", "1e2", "٣"]) expect(parseCovers(bad), bad).toBeNull();
  });
  const base = { askCovers: true, orderType: "dine_in", adding: false, offline: false, text: "" };
  it("dine-in on the order screen needs at least 1 guest", () => {
    expect(coversError(base)).toMatch(/number of guests/);
    expect(coversError({ ...base, text: "0" })).toMatch(/number of guests/);
    expect(coversError({ ...base, text: "4" })).toBeNull();
  });
  it("is not asked for takeaway, delivery, adding to a bill, offline, or on the classic screen", () => {
    expect(coversError({ ...base, orderType: "takeaway" })).toBeNull();
    expect(coversError({ ...base, orderType: "delivery" })).toBeNull();
    expect(coversError({ ...base, adding: true })).toBeNull();
    expect(coversError({ ...base, offline: true })).toBeNull();
    expect(coversError({ ...base, askCovers: false })).toBeNull();
  });
});

describe("needs-internet words", () => {
  it("every feature has a sentence that says internet", () => {
    for (const k of ["add_to_bill", "tip", "open_price", "move_item", "repeat_round", "bill_action", "loyalty_redeem"] as const) {
      expect(needsInternetText(k).toLowerCase(), k).toContain("internet");
    }
  });
});

describe("discardQuestion", () => {
  it("asks only when something would be lost", () => {
    expect(discardQuestion(0)).toBeNull();
    expect(discardQuestion(-1)).toBeNull();
    expect(discardQuestion(1)).toMatch(/^1 item has not been sent/);
    expect(discardQuestion(3)).toMatch(/^3 items have not been sent/);
  });
});

describe("open price entry", () => {
  it("accepts an amount above zero with at most two decimals", () => {
    for (const ok of ["1", "150", "99.5", "99.50", "0.01", " 12 "]) expect(openPriceError(ok), ok).toBeNull();
  });
  it("refuses zero, negatives, three decimals, commas, empty, signs and exponents", () => {
    for (const bad of ["", "0", "0.00", "-5", "1.234", "1,5", "abc", "1e3", "+5", "123456789"]) expect(openPriceError(bad), bad).not.toBeNull();
  });
  it("rounds to two decimals", () => {
    expect(openPriceValue("99.5")).toBe(99.5);
    expect(openPriceValue(" 12 ")).toBe(12);
    expect(openPriceValue("0.07")).toBe(0.07);
  });
});
