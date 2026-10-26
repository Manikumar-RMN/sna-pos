import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * The menu form must never clear a dish flag by accident (past QA blocker: a save without the
 * checkbox cleared is_open_price). Each flag is written only when its hidden "*_present" marker is "1".
 */

type Call = { table: string; op: "update" | "insert"; row: Record<string, unknown>; eq?: [string, unknown] };
const calls: Call[] = [];
let parentRow: Record<string, unknown> | null = null;

function builder(table: string) {
  let pending: Call | null = null;
  const b: Record<string, unknown> = {};
  const done = () => Promise.resolve({ data: null, error: null });
  b.update = (row: Record<string, unknown>) => { pending = { table, op: "update", row }; calls.push(pending); return b; };
  b.insert = (row: Record<string, unknown>) => { pending = { table, op: "insert", row }; calls.push(pending); return b; };
  b.select = () => b;
  b.delete = () => b;
  b.eq = (col: string, val: unknown) => { if (pending) pending.eq = [col, val]; return b; };
  b.is = () => b;
  b.not = () => b;
  b.single = () => Promise.resolve({ data: { id: "new-id" }, error: null });
  b.maybeSingle = () => Promise.resolve({ data: parentRow, error: null });
  b.then = (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) => done().then(res, rej);
  return b;
}

vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ from: (t: string) => builder(t) }) }));
vi.mock("@/lib/auth", () => ({
  getCurrentUser: async () => ({ id: "u1", restaurant_id: "r1", country_code: "IN" }),
  can: () => true,
}));

import { addSize, createProduct, updateProduct } from "./actions";

function form(fields: Record<string, string>): FormData {
  const f = new FormData();
  for (const [k, v] of Object.entries(fields)) f.append(k, v);
  return f;
}
const base = { id: "p1", name: "Dosa", category_id: "c1", tax_group_id: "t1", price: "60" };
const prev = { error: null };
const productUpdate = () => calls.find((c) => c.table === "products" && c.op === "update" && c.eq?.[0] === "id")!;
const sizesUpdate = () => calls.find((c) => c.table === "products" && c.op === "update" && c.eq?.[0] === "parent_id")!;

beforeEach(() => {
  calls.length = 0;
  parentRow = null;
});

describe("updateProduct flag guards", () => {
  it("a form without any marker sends none of the three flags", async () => {
    const r = await updateProduct(prev, form(base));
    expect(r.ok).toBe(true);
    const row = productUpdate().row;
    expect(row).not.toHaveProperty("is_open_price");
    expect(row).not.toHaveProperty("discount_restricted");
    expect(row).not.toHaveProperty("prep_minutes");
    const sizes = sizesUpdate().row;
    expect(sizes).not.toHaveProperty("discount_restricted");
    expect(sizes).not.toHaveProperty("prep_minutes");
  });

  it("a stray prep value or checkbox without the marker is still ignored", async () => {
    await updateProduct(prev, form({ ...base, prep_minutes: "12", discount_restricted: "on", is_open_price: "on" }));
    const row = productUpdate().row;
    expect(row).not.toHaveProperty("is_open_price");
    expect(row).not.toHaveProperty("discount_restricted");
    expect(row).not.toHaveProperty("prep_minutes");
  });

  it("marker present and checkbox unticked writes false", async () => {
    await updateProduct(prev, form({ ...base, discount_restricted_present: "1" }));
    expect(productUpdate().row.discount_restricted).toBe(false);
    expect(sizesUpdate().row.discount_restricted).toBe(false);
  });

  it("marker present and checkbox ticked writes true", async () => {
    await updateProduct(prev, form({ ...base, discount_restricted_present: "1", discount_restricted: "on" }));
    expect(productUpdate().row.discount_restricted).toBe(true);
    expect(sizesUpdate().row.discount_restricted).toBe(true);
  });

  it("prep marker with an empty box clears to null; with 12 writes 12 (dish and sizes)", async () => {
    await updateProduct(prev, form({ ...base, prep_present: "1", prep_minutes: "" }));
    expect(productUpdate().row.prep_minutes).toBeNull();
    calls.length = 0;
    await updateProduct(prev, form({ ...base, prep_present: "1", prep_minutes: "12" }));
    expect(productUpdate().row.prep_minutes).toBe(12);
    expect(sizesUpdate().row.prep_minutes).toBe(12);
  });

  it("open price keeps its own guard and is not copied to sizes", async () => {
    await updateProduct(prev, form({ ...base, open_price_present: "1" }));
    expect(productUpdate().row.is_open_price).toBe(false);
    expect(sizesUpdate().row).not.toHaveProperty("is_open_price");
  });

  it("refuses prep time outside 1 to 240 and non-numbers, and writes nothing", async () => {
    for (const bad of ["0", "241", "-3", "1.5", "abc", "1e2"]) {
      calls.length = 0;
      const r = await updateProduct(prev, form({ ...base, prep_present: "1", prep_minutes: bad }));
      expect(r.error, bad).toBe("Preparation time is 1 to 240 minutes.");
      expect(calls, bad).toHaveLength(0);
    }
  });

  it("accepts the limits 1 and 240", async () => {
    for (const ok of ["1", "240"]) {
      calls.length = 0;
      const r = await updateProduct(prev, form({ ...base, prep_present: "1", prep_minutes: ok }));
      expect(r.ok, ok).toBe(true);
      expect(productUpdate().row.prep_minutes).toBe(Number(ok));
    }
  });

  it("a bad prep value does not block a save that did not carry the field", async () => {
    const r = await updateProduct(prev, form({ ...base, prep_minutes: "999" }));
    expect(r.ok).toBe(true);
  });
});

describe("createProduct", () => {
  it("writes both new fields", async () => {
    const r = await createProduct(prev, form({ ...base, discount_restricted: "on", prep_minutes: "8" }));
    expect(r.ok).toBe(true);
    const ins = calls.find((c) => c.op === "insert" && c.table === "products")!;
    expect(ins.row.discount_restricted).toBe(true);
    expect(ins.row.prep_minutes).toBe(8);
  });
  it("defaults to false / null", async () => {
    await createProduct(prev, form(base));
    const ins = calls.find((c) => c.op === "insert" && c.table === "products")!;
    expect(ins.row.discount_restricted).toBe(false);
    expect(ins.row.prep_minutes).toBeNull();
  });
  it("refuses a bad prep time", async () => {
    const r = await createProduct(prev, form({ ...base, prep_minutes: "300" }));
    expect(r.error).toBe("Preparation time is 1 to 240 minutes.");
    expect(calls).toHaveLength(0);
  });
});

describe("addSize", () => {
  it("copies No discount and prep time from the dish", async () => {
    parentRow = { id: "p1", name: "Dosa", category_id: "c1", tax_group_id: "t1", is_veg: true, kitchen_station: null, hsn_code: null, parent_id: null, discount_restricted: true, prep_minutes: 10 };
    const r = await addSize("p1", "Large", "80");
    expect(r.ok).toBe(true);
    const ins = calls.find((c) => c.op === "insert")!;
    expect(ins.row.discount_restricted).toBe(true);
    expect(ins.row.prep_minutes).toBe(10);
  });
});
