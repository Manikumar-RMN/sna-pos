import { describe, expect, it } from "vitest";
import { maxPrep, prepOf, type PrepProduct } from "./prep";

const byId = new Map<string, PrepProduct>(
  [
    { id: "dish", parent_id: null, prep_minutes: 12 },
    { id: "small", parent_id: "dish", prep_minutes: null },
    { id: "large", parent_id: "dish", prep_minutes: 20 },
    { id: "tea", parent_id: null, prep_minutes: null },
    { id: "fries", parent_id: null, prep_minutes: 8 },
  ].map((p) => [p.id, p]),
);

describe("KOT prep time", () => {
  it("a size without its own time uses its dish's", () => {
    expect(prepOf("small", byId)).toBe(12);
    expect(prepOf("large", byId)).toBe(20);
  });
  it("no time anywhere is null", () => {
    expect(prepOf("tea", byId)).toBeNull();
    expect(prepOf("unknown", byId)).toBeNull();
    expect(prepOf(null, byId)).toBeNull();
  });
  it("a ticket uses the longest time among its items", () => {
    expect(maxPrep(["fries", "small", "tea"], byId)).toBe(12);
    expect(maxPrep(["fries", "large"], byId)).toBe(20);
  });
  it("a ticket with no timed item prints nothing", () => {
    expect(maxPrep(["tea"], byId)).toBeNull();
    expect(maxPrep([], byId)).toBeNull();
  });
});
