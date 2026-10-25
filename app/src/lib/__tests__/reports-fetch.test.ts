import { describe, expect, it } from "vitest";
import { inChunks, IN_CHUNK } from "../reports-fetch";

describe("inChunks", () => {
  it("splits ids into groups and stops at the first error", async () => {
    const sizes: number[] = [];
    const ids = Array.from({ length: IN_CHUNK * 2 + 5 }, (_, i) => String(i));
    const ok = await inChunks<string>(ids, async (c) => {
      sizes.push(c.length);
      return { data: c, error: null };
    });
    expect(sizes).toEqual([IN_CHUNK, IN_CHUNK, 5]);
    expect(ok.rows).toHaveLength(ids.length);
    let n = 0;
    const bad = await inChunks<string>(ids, async () => (++n === 2 ? { data: null, error: { message: "x" } } : { data: ["a"], error: null }));
    expect(bad.error?.message).toBe("x");
    expect(n).toBe(2);
  });
});
