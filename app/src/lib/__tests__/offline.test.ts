import { describe, expect, it } from "vitest";
import { discountPool, offlineQuote, type Snapshot, type SnapItem } from "../offline";

const gst = [{ name: "CGST", rate: 9 }, { name: "SGST", rate: 9 }];
const item = (id: string, price: number, extra: Partial<SnapItem> = {}): SnapItem => ({
  id,
  name: id,
  short_name: null,
  price,
  category_id: "c",
  category_name: "Food",
  is_veg: null,
  station: "Kitchen",
  inclusive: false,
  comps: gst,
  groups: [],
  ...extra,
});
function snap(menu: SnapItem[]): Snapshot {
  return {
    taken_at: "2026-10-26T00:00:00Z",
    device_key: "d",
    series: { prefix: "X1", fy: null, next_seq: 1, branch_code: "BILL" },
    rights: { discount: true, pay: true },
    menu,
    methods: [],
    settings: { sc_percent: 0, sc_taxable: false, sc_default_on: false, sc_label: "Service charge", rounding: "none", cash_rounding: "none" },
    receipt: { header: "", legal_name: "", tax_id: null, tax_id_label: null, fssai_no: null, footer: null, currency: "INR", timezone: "Asia/Kolkata", country: "IN", invoice_title: null },
  };
}

describe("offline discount block", () => {
  const s = snap([item("a", 100, { no_discount: true }), item("b", 100), item("old", 100)]);
  const lines = [
    { product_id: "a", qty: 1, unit_price: 100 },
    { product_id: "b", qty: 1, unit_price: 100 },
  ];

  it("a dish marked no-discount in the copy takes no part of the discount", () => {
    const c = offlineQuote(s, lines, 20, null);
    expect(c.discount).toBe(20);
    expect(c.lines[0].discount).toBe(0);
    expect(c.lines[1].discount).toBe(20);
    expect(c.grand_total).toBe(212.4);
  });

  it("the discount is cut to the pool, never more", () => {
    const c = offlineQuote(s, lines, 500, null);
    expect(c.discount).toBe(100);
    expect(c.discountable_subtotal).toBe(100);
  });

  it("discountPool is the part a percent is worked out on", () => {
    expect(discountPool(s, lines)).toBe(100);
    expect(discountPool(s, [{ product_id: "a", qty: 2, unit_price: 100 }])).toBe(0);
    expect(discountPool(null, lines)).toBe(200);
  });

  it("an older copy without the flag reads as discountable (the server corrects it on sync)", () => {
    const old = snap([{ ...item("a", 100) }, item("b", 100)]);
    expect(offlineQuote(old, lines, 20, null).lines[0].discount).toBe(10);
  });

  it("an item missing from the copy is treated as discountable with no tax", () => {
    expect(discountPool(s, [{ product_id: "zzz", qty: 1, unit_price: 40 }])).toBe(40);
  });
});
