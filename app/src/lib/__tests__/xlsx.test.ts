import { describe, expect, it } from "vitest";
import { buildXlsx } from "../xlsx";

describe("buildXlsx", () => {
  it("writes a zip with a sheet per section, safe sheet names and numbers kept as numbers", () => {
    const bytes = buildXlsx([
      { name: "GST / tax", header: ["Item", "Value"], rows: [["A & B", 12.5], ["=1+1", 3]] },
      { name: "GST / tax", header: ["X"], rows: [] },
    ]);
    expect(bytes[0]).toBe(0x50); // "PK"
    expect(bytes[1]).toBe(0x4b);
    const text = new TextDecoder("latin1").decode(bytes);
    expect(text).toContain("xl/worksheets/sheet2.xml");
    expect(text).toContain('name="GST - tax"');
    expect(text).toContain('name="GST - tax 2"');
    expect(text).toContain("A &amp; B");
    expect(text).toContain("<v>12.5</v>");
  });
  it("still builds a workbook with no sheets", () => {
    expect(buildXlsx([]).length).toBeGreaterThan(100);
  });
});
