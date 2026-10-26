import { describe, expect, it } from "vitest";
import { kitchenLate, prepMinutesByOrderItem } from "./prep";

type Rows = Record<string, unknown[] | null>;
/** A tiny stand-in for the supabase client: from(table).select().in() answers with the rows given for that table. */
const fake = (rows: Rows, failTable?: string) => ({
  from: (t: string) => ({
    select: () => ({
      in: async (_c: string, ids: string[]) =>
        t === failTable
          ? { data: null, error: { message: "column does not exist" } }
          : { data: (rows[t] ?? []).filter((r) => ids.includes((r as { id: string }).id)), error: null },
    }),
  }),
});

describe("kitchenLate", () => {
  it("uses prep plus 5 minutes grace (strictly more)", () => {
    expect(kitchenLate(17, 12)).toBe(false);
    expect(kitchenLate(18, 12)).toBe(true);
    expect(kitchenLate(25, 30)).toBe(false);
  });
  it("falls back to the old 15 minutes with no prep time", () => {
    expect(kitchenLate(14, null)).toBe(false);
    expect(kitchenLate(15, undefined)).toBe(true);
    expect(kitchenLate(15, 0)).toBe(true);
  });
});

describe("prepMinutesByOrderItem", () => {
  it("reads the dish prep and lets a size inherit it", async () => {
    const db = fake({
      order_items: [
        { id: "i1", product_id: "dish" },
        { id: "i2", product_id: "sizeA" },
        { id: "i3", product_id: "sizeB" },
        { id: "i4", product_id: "none" },
      ],
      products: [
        { id: "dish", parent_id: null, prep_minutes: 12 },
        { id: "sizeA", parent_id: "dish", prep_minutes: null },
        { id: "sizeB", parent_id: "dish", prep_minutes: 20 },
        { id: "none", parent_id: null, prep_minutes: null },
      ],
    });
    const m = await prepMinutesByOrderItem(db, ["i1", "i2", "i3", "i4"]);
    expect(m.get("i1")).toBe(12);
    expect(m.get("i2")).toBe(12);
    expect(m.get("i3")).toBe(20);
    expect(m.has("i4")).toBe(false);
  });
  it("gives an empty map when the column is not there yet or nothing is asked", async () => {
    expect((await prepMinutesByOrderItem(fake({ order_items: [{ id: "i1", product_id: "p" }] }, "products"), ["i1"])).size).toBe(0);
    expect((await prepMinutesByOrderItem(fake({}), [])).size).toBe(0);
    expect((await prepMinutesByOrderItem({}, ["x"])).size).toBe(0);
  });
});
