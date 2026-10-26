import { describe, expect, it } from "vitest";
import { rightGroups, rightLabel } from "../permissions";

describe("rightGroups", () => {
  it("lists every right once", () => {
    const keys = rightGroups().flatMap((g) => g.rights.map((r) => r.key));
    expect(new Set(keys).size).toBe(keys.length);
  });
  it("names the reprint right for bills and KOTs", () => {
    expect(rightLabel("order.reprint")).toBe("Reprint bills and KOTs");
  });
  it("lists the open price right in the Billing group", () => {
    const billing = rightGroups().find((g) => g.name === "Billing");
    expect(billing?.rights.map((r) => r.key)).toContain("order.open_price");
  });
  it("falls back to the key for an unknown right", () => {
    expect(rightLabel("nothing.here")).toBe("nothing.here");
  });
});
