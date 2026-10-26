import { describe, expect, it } from "vitest";
import { MAX_TIP, parseTip, suggestTip, tipError, tipForRequest, tipText } from "./tip";

describe("parseTip", () => {
  it("empty means no tip", () => {
    expect(parseTip("")).toEqual({ ok: true, value: 0 });
    expect(parseTip("   ")).toEqual({ ok: true, value: 0 });
  });
  it("accepts whole and two-decimal amounts", () => {
    expect(parseTip("50")).toEqual({ ok: true, value: 50 });
    expect(parseTip("12.5")).toEqual({ ok: true, value: 12.5 });
    expect(parseTip("12.50")).toEqual({ ok: true, value: 12.5 });
    expect(parseTip("0.05")).toEqual({ ok: true, value: 0.05 });
  });
  it("refuses negatives, signs, letters, exponents, commas and a third decimal", () => {
    for (const bad of ["-5", "+5", "abc", "1e3", "12.345", ".", "1 000", "10%", "1,25", "1,250"]) {
      expect(parseTip(bad).ok, bad).toBe(false);
    }
  });
  it("refuses an absurd tip", () => {
    expect(parseTip("100000000").ok).toBe(false);
    expect(parseTip(String(MAX_TIP)).ok).toBe(true);
  });
});

describe("suggestTip", () => {
  it("rounds to a whole unit", () => {
    expect(suggestTip(473.5, 10)).toBe(47);
    expect(suggestTip(1000, 5)).toBe(50);
    expect(suggestTip(333.33, 15)).toBe(50);
  });
  it("is 0 for anything it cannot work out", () => {
    expect(suggestTip(0, 10)).toBe(0);
    expect(suggestTip(-5, 10)).toBe(0);
    expect(suggestTip(100, 0)).toBe(0);
    expect(suggestTip(Number.NaN, 10)).toBe(0);
  });
});

describe("tipText / tipForRequest", () => {
  it("formats a suggestion for the box", () => {
    expect(tipText(50)).toBe("50");
    expect(tipText(0)).toBe("");
  });
  it("sends nothing when there is no tip or the entry is bad", () => {
    expect(tipForRequest("")).toBeUndefined();
    expect(tipForRequest("0")).toBeUndefined();
    expect(tipForRequest("abc")).toBeUndefined();
    expect(tipForRequest("25.5")).toBe(25.5);
  });
});

describe("tipError", () => {
  it("is null for empty and good entries, a sentence for bad ones", () => {
    expect(tipError("")).toBeNull();
    expect(tipError("40")).toBeNull();
    expect(tipError("-1")).toMatch(/amount/);
  });
});
