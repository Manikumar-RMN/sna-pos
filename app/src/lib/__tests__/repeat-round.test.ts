import { describe, expect, it } from "vitest";
import { buildRoundLines, mapRoundToMenu, pickRoundTickets, type RoundLine, type RoundMenuItem } from "../repeat-round";

const t0 = Date.parse("2026-10-25T12:00:00.000Z");
const iso = (secondsFromT0: number) => new Date(t0 + secondsFromT0 * 1000).toISOString();

describe("pickRoundTickets", () => {
  it("takes the newest ticket and the ones made within a minute before it", () => {
    const ids = pickRoundTickets([
      { id: "old", created_at: iso(-600), status: "ready" },
      { id: "a", created_at: iso(-30), status: "new" },
      { id: "b", created_at: iso(0), status: "new" },
    ]);
    expect(ids).toEqual(["a", "b"]);
  });
  it("is exactly 60 seconds wide", () => {
    expect(pickRoundTickets([{ id: "a", created_at: iso(-60), status: "new" }, { id: "b", created_at: iso(0), status: "new" }])).toEqual(["a", "b"]);
    expect(pickRoundTickets([{ id: "a", created_at: iso(-61), status: "new" }, { id: "b", created_at: iso(0), status: "new" }])).toEqual(["b"]);
  });
  it("ignores cancelled tickets, even the newest", () => {
    expect(pickRoundTickets([{ id: "a", created_at: iso(-300), status: "ready" }, { id: "b", created_at: iso(0), status: "cancelled" }])).toEqual(["a"]);
  });
  it("is empty without tickets", () => {
    expect(pickRoundTickets([])).toEqual([]);
    expect(pickRoundTickets([{ id: "x", created_at: "junk", status: "new" }])).toEqual([]);
  });
});

describe("buildRoundLines", () => {
  const oi = [
    { id: "l1", product_id: "dosa", product_name: "Masala Dosa", kitchen_note: null, cancelled_at: null },
    { id: "l2", product_id: "dosa", product_name: "Masala Dosa", kitchen_note: "No onion", cancelled_at: null },
    { id: "l3", product_id: "tea", product_name: "Tea", kitchen_note: " ", cancelled_at: null },
    { id: "l4", product_id: "cola", product_name: "Cola", kitchen_note: null, cancelled_at: "2026-10-25T12:01:00Z" },
    { id: "l5", product_id: "dosa", product_name: "Masala Dosa", kitchen_note: null, cancelled_at: null },
  ];
  it("keeps dish, options, quantity and note; never a price", () => {
    const lines = buildRoundLines(
      [{ order_item_id: "l2", quantity: 1, status: "new" }],
      oi,
      [{ order_item_id: "l2", modifier_item_id: "m2" }, { order_item_id: "l2", modifier_item_id: "m1" }],
    );
    expect(lines).toEqual([{ p: "dosa", nm: "Masala Dosa", o: ["m1", "m2"], q: 1, n: "No onion" }]);
    expect(Object.keys(lines[0]).sort()).toEqual(["n", "nm", "o", "p", "q"]);
  });
  it("adds equal lines together and keeps different notes apart", () => {
    const lines = buildRoundLines(
      [
        { order_item_id: "l1", quantity: 2, status: "new" },
        { order_item_id: "l5", quantity: 1, status: "new" },
        { order_item_id: "l2", quantity: 1, status: "new" },
      ],
      oi,
      [],
    );
    expect(lines).toHaveLength(2);
    expect(lines.find((l) => l.n === "")?.q).toBe(3);
    expect(lines.find((l) => l.n === "No onion")?.q).toBe(1);
  });
  it("skips cancelled kitchen lines, cancelled bill lines, unknown lines and zero quantities", () => {
    const lines = buildRoundLines(
      [
        { order_item_id: "l1", quantity: 1, status: "cancelled" },
        { order_item_id: "l4", quantity: 1, status: "new" },
        { order_item_id: "zz", quantity: 1, status: "new" },
        { order_item_id: "l3", quantity: 0, status: "new" },
        { order_item_id: "l3", quantity: 2, status: "ready" },
      ],
      oi,
      [],
    );
    expect(lines).toEqual([{ p: "tea", nm: "Tea", o: [], q: 2, n: "" }]);
  });
  it("ignores modifier rows without an id and repeated ids", () => {
    const lines = buildRoundLines(
      [{ order_item_id: "l1", quantity: 1, status: "new" }],
      oi,
      [{ order_item_id: "l1", modifier_item_id: null }, { order_item_id: "l1", modifier_item_id: "m1" }, { order_item_id: "l1", modifier_item_id: "m1" }],
    );
    expect(lines[0].o).toEqual(["m1"]);
  });
});

describe("mapRoundToMenu", () => {
  const menu: (RoundMenuItem & { price: number })[] = [
    { id: "dosa", name: "Masala Dosa", price: 130, groups: [{ options: [{ id: "m1", name: "Extra ghee", price: 10 }, { id: "m2", name: "Cheese", price: 20 }] }] },
    { id: "tea", name: "Tea", price: 25, groups: [] },
    { id: "fish", name: "Fish by weight", price: 600, byWeight: true, groups: [] },
    { id: "pack", name: "Packing", price: 5, groups: [] },
  ];
  const line = (over: Partial<RoundLine>): RoundLine => ({ p: "tea", nm: "Tea", o: [], q: 1, n: "", ...over });

  it("takes the dish and the options from TODAY's menu, so prices are today's", () => {
    const r = mapRoundToMenu([line({ p: "dosa", nm: "Masala Dosa", o: ["m1", "m2"], q: 2, n: "No onion" })], menu, "pack");
    expect(r.message).toBeNull();
    expect(r.lines).toHaveLength(1);
    expect(r.lines[0].item.price).toBe(130);
    expect(r.lines[0].options.map((o) => o.price)).toEqual([10, 20]);
    expect(r.lines[0].qty).toBe(2);
    expect(r.lines[0].note).toBe("No onion");
  });
  it("skips a dish that is no longer on the menu and says so", () => {
    const r = mapRoundToMenu([line({}), line({ p: "gone", nm: "Old Special" })], menu, null);
    expect(r.lines).toHaveLength(1);
    expect(r.skipped).toEqual([{ name: "Old Special", why: "not_on_menu" }]);
    expect(r.message).toContain("Old Special");
    expect(r.message).toContain("1 item was");
  });
  it("skips a line whose option is gone", () => {
    const r = mapRoundToMenu([line({ p: "dosa", nm: "Masala Dosa", o: ["m1", "mX"] })], menu, null);
    expect(r.lines).toHaveLength(0);
    expect(r.skipped[0].why).toBe("option_changed");
  });
  it("never repeats the packing charge, and does not complain about it", () => {
    const r = mapRoundToMenu([line({ p: "pack", nm: "Packing" })], menu, "pack");
    expect(r.lines).toHaveLength(0);
    expect(r.message).toBeNull();
  });
  it("whole quantities only, except for items sold by weight", () => {
    expect(mapRoundToMenu([line({ q: 1.5 })], menu, null).lines).toHaveLength(0);
    expect(mapRoundToMenu([line({ q: 0 })], menu, null).skipped[0].why).toBe("bad_quantity");
    expect(mapRoundToMenu([line({ p: "fish", nm: "Fish", q: 0.75 })], menu, null).lines[0].qty).toBe(0.75);
  });
  it("lists at most four names in the message", () => {
    const many = ["a", "b", "c", "d", "e", "f"].map((x) => line({ p: x, nm: x.toUpperCase() }));
    const r = mapRoundToMenu(many, menu, null);
    expect(r.message).toContain("6 items were");
    expect(r.message).toContain("A, B, C, D, ...");
  });
});
