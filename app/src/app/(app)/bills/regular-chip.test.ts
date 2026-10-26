import { describe, expect, it } from "vitest";
import { regularChipText } from "./loyalty-math";

const g = (visits: number, points: number) => ({ id: "x", name: "A", visits, lastVisitOn: null, points });

describe("regularChipText", () => {
  it("regular with points", () => expect(regularChipText(g(7, 120), true)).toBe("Regular - 7 visits, 120 points"));
  it("hides points when loyalty is off", () => expect(regularChipText(g(7, 120), false)).toBe("Regular - 7 visits"));
  it("one visit is returning", () => expect(regularChipText(g(1, 0), true)).toBe("Returning - 1 visit"));
  it("no visits shows nothing", () => expect(regularChipText(g(0, 5), true)).toBeNull());
});
