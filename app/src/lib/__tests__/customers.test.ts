import { describe, expect, it } from "vitest";
import {
  csvCell,
  customerCsvRows,
  customersHref,
  daysBetween,
  formatPhone,
  isLapsed,
  lastVisitText,
  ledgerKindLabel,
  loyaltyExample,
  parseCustomerDetail,
  parseCustomerList,
  parseFilter,
  parsePage,
  parseSort,
  searchHint,
  searchText,
  signedPoints,
  toCsv,
  validateCustomerEdit,
  validateLoyaltyRules,
} from "../customers";

describe("list options from the address bar", () => {
  it("falls back to safe values", () => {
    expect(parseFilter("repeat")).toBe("repeat");
    expect(parseFilter("bogus")).toBe("all");
    expect(parseFilter(undefined)).toBe("all");
    expect(parseSort("points")).toBe("points");
    expect(parseSort("; drop table")).toBe("last_visit");
    expect(parsePage("3")).toBe(3);
    expect(parsePage("0")).toBe(1);
    expect(parsePage("-2")).toBe(1);
    expect(parsePage("1.5")).toBe(1);
    expect(parsePage("abc")).toBe(1);
  });
  it("searches only with 3 or more characters", () => {
    expect(searchText("  ab ")).toBe("");
    expect(searchText("  987  65 ")).toBe("987 65");
    expect(searchHint("ab")).toMatch(/at least 3/);
    expect(searchHint("")).toBeNull();
    expect(searchHint("abc")).toBeNull();
  });
  it("builds short links and leaves defaults out", () => {
    expect(customersHref({})).toBe("/customers");
    expect(customersHref({ q: " ravi ", filter: "repeat", sort: "points", page: 2 })).toBe("/customers?q=ravi&filter=repeat&sort=points&page=2");
    expect(customersHref({ filter: "all", sort: "last_visit", page: 1 })).toBe("/customers");
  });
});

describe("parseCustomerList", () => {
  it("reads rows and keeps total at least as large as the rows", () => {
    const r = parseCustomerList({
      total: "2",
      rows: [
        { id: "a", name: "Ravi", phone: "9876543210", visits: 3, spend: "1250.50", avg_bill: 416.83, first_visit_on: "2026-09-01", last_visit_on: "2026-10-20", points: 12, marketing_consent: true },
        { id: "b", name: null, phone: "+919000000000", visits: 0, spend: 0, avg_bill: 0, points: 0 },
        { name: "no id" },
      ],
    });
    expect(r.total).toBe(2);
    expect(r.rows).toHaveLength(2);
    expect(r.rows[0]).toMatchObject({ id: "a", spend: 1250.5, lastVisitOn: "2026-10-20", marketingConsent: true });
    expect(r.rows[1]).toMatchObject({ name: "Guest", lastVisitOn: null, marketingConsent: false });
  });
  it("gives an empty list for anything else", () => {
    expect(parseCustomerList(null)).toEqual({ total: 0, rows: [] });
    expect(parseCustomerList("x")).toEqual({ total: 0, rows: [] });
    expect(parseCustomerList({ total: 5 }).rows).toEqual([]);
  });
});

describe("parseCustomerDetail", () => {
  const raw = {
    profile: { id: "c1", name: "Ravi", phone: "9876543210", email: "r@x.in", notes: "", date_of_birth: "1990-04-02", marketing_consent: true, consent_given_at: "2026-10-01T10:00:00Z" },
    stats: { visits: 4, spend: 2000, avg_bill: 500, first_visit_on: "2026-09-01", last_visit_on: "2026-10-20" },
    points_balance: 40, points_expire: false,
    points_note: "Points do not expire.",
    account_balance: "150",
    bills: [{ id: "o1", bill_number: "B-12", business_date: "2026-10-20", outlet: "Main", total: 500, refunded: 0, payment_mode: "UPI", points_earned: 5, points_redeemed: 0, status: "closed", payment_status: "paid", is_visit: true }, { bill_number: "no id" }],
    ledger: [{ at: "2026-10-20T12:00:00Z", kind: "earn", points: 5, bill_number: "B-12" }],
  };
  it("reads the profile, stats, bills and ledger", () => {
    const d = parseCustomerDetail(raw)!;
    expect(d).toMatchObject({ id: "c1", email: "r@x.in", notes: null, birthday: "1990-04-02", visits: 4, points: 40, accountBalance: 150, expiryNote: "Points do not expire." });
    expect(d.bills).toHaveLength(1);
    expect(d.bills[0]).toMatchObject({ paymentStatus: "paid", isVisit: true });
    expect(d.ledger[0]).toMatchObject({ kind: "earn", points: 5, billNumber: "B-12" });
  });
  it("accepts flat fields and returns null without an id", () => {
    expect(parseCustomerDetail({ id: "c2", name: "A", visits: 1, spend: 10 })).toMatchObject({ id: "c2", visits: 1, spend: 10, accountBalance: null });
    expect(parseCustomerDetail({})).toBeNull();
    expect(parseCustomerDetail(null)).toBeNull();
  });
});

describe("showing values", () => {
  it("groups phone numbers", () => {
    expect(formatPhone("9876543210")).toBe("98765 43210");
    expect(formatPhone("+919876543210")).toBe("+91 98765 43210");
    expect(formatPhone("12345")).toBe("12345");
    expect(formatPhone("")).toBe("—");
    expect(formatPhone(null)).toBe("—");
  });
  it("counts days and words them", () => {
    expect(daysBetween("2026-10-20", "2026-10-25")).toBe(5);
    expect(daysBetween(null, "2026-10-25")).toBeNull();
    expect(daysBetween("junk", "2026-10-25")).toBeNull();
    expect(lastVisitText(null, "2026-10-25")).toBe("Never");
    expect(lastVisitText("2026-10-25", "2026-10-25")).toBe("Today");
    expect(lastVisitText("2026-10-24", "2026-10-25")).toBe("Yesterday");
    expect(lastVisitText("2026-10-13", "2026-10-25")).toBe("12 days ago");
    expect(lastVisitText("2026-07-25", "2026-10-25")).toBe("3 months ago");
    expect(lastVisitText("2023-10-25", "2026-10-25")).toBe("3 years ago");
  });
  it("lapsed means more than 60 days", () => {
    expect(isLapsed("2026-08-26", "2026-10-25")).toBe(false); // 60 days
    expect(isLapsed("2026-08-25", "2026-10-25")).toBe(true); // 61 days
    expect(isLapsed(null, "2026-10-25")).toBe(false);
  });
  it("labels the ledger", () => {
    expect(ledgerKindLabel("earn")).toBe("Earned");
    expect(ledgerKindLabel("expire")).toBe("Expired");
    expect(ledgerKindLabel("zzz")).toBe("zzz");
    expect(signedPoints(5)).toBe("+5");
    expect(signedPoints(-40)).toBe("−40");
    expect(signedPoints(0)).toBe("0");
  });
});

describe("CSV export", () => {
  it("quotes cells and defuses spreadsheet formulas", () => {
    expect(csvCell("plain")).toBe("plain");
    expect(csvCell('a,"b"')).toBe('"a,""b"""');
    expect(csvCell("=HYPERLINK(1)")).toBe("'=HYPERLINK(1)");
    expect(csvCell("+919876543210")).toBe("'+919876543210");
    expect(csvCell(-5)).toBe("-5");
  });
  it("builds the file with a byte-order mark and CRLF lines", () => {
    const rows = customerCsvRows([{ id: "a", name: "Ravi, K", phone: "9876543210", visits: 2, spend: 100, avgBill: 50, firstVisitOn: "2026-09-01", lastVisitOn: null, points: 3, marketingConsent: false }]);
    const csv = toCsv(["Name", "Phone"], [["Ravi, K", "9876543210"]]);
    expect(csv.startsWith("﻿")).toBe(true);
    expect(csv.split("\r\n")).toEqual(["﻿Name,Phone", '"Ravi, K",9876543210']);
    expect(rows[0]).toEqual(["Ravi, K", "9876543210", 2, 100, 50, "2026-09-01", "", 3, "No"]);
  });
});

describe("validateCustomerEdit", () => {
  const ok = { name: "  Ravi   Kumar ", email: " r@x.in ", notes: " vip ", birthday: "1990-04-02", consent: true };
  it("cleans good input", () => {
    expect(validateCustomerEdit(ok, "2026-10-25")).toEqual({ ok: true, name: "Ravi Kumar", email: "r@x.in", notes: "vip", birthday: "1990-04-02", consent: true });
    expect(validateCustomerEdit({ ...ok, email: "", notes: "", birthday: "" }, "2026-10-25")).toMatchObject({ ok: true, email: null, notes: null, birthday: null });
  });
  it("explains what to fix", () => {
    expect(validateCustomerEdit({ ...ok, name: "  " }, "2026-10-25")).toMatchObject({ ok: false, error: expect.stringMatching(/name/) });
    expect(validateCustomerEdit({ ...ok, name: "x".repeat(81) }, "2026-10-25")).toMatchObject({ ok: false });
    expect(validateCustomerEdit({ ...ok, email: "nope" }, "2026-10-25")).toMatchObject({ ok: false, error: expect.stringMatching(/email/) });
    expect(validateCustomerEdit({ ...ok, notes: "x".repeat(501) }, "2026-10-25")).toMatchObject({ ok: false, error: expect.stringMatching(/500/) });
    expect(validateCustomerEdit({ ...ok, birthday: "2026-02-31" }, "2026-10-25")).toMatchObject({ ok: false, error: expect.stringMatching(/real date/) });
    expect(validateCustomerEdit({ ...ok, birthday: "2027-01-01" }, "2026-10-25")).toMatchObject({ ok: false, error: expect.stringMatching(/future/) });
    expect(validateCustomerEdit({ ...ok, birthday: "1800-01-01" }, "2026-10-25")).toMatchObject({ ok: false });
  });
});

describe("validateLoyaltyRules", () => {
  const base = { spend: "100", value: "1", min: "50", mode: "discount", maxPercent: "50" };
  it("accepts both redeem modes", () => {
    expect(validateLoyaltyRules(base)).toEqual({ ok: true, spend: 100, value: 1, min: 50, mode: "discount", maxPercent: 50 });
    expect(validateLoyaltyRules({ ...base, mode: "tender", min: "", maxPercent: "" })).toEqual({ ok: true, spend: 100, value: 1, min: 0, mode: "tender", maxPercent: 100 });
  });
  it("refuses bad numbers and modes", () => {
    expect(validateLoyaltyRules({ ...base, spend: "0" })).toMatchObject({ ok: false });
    expect(validateLoyaltyRules({ ...base, spend: "abc" })).toMatchObject({ ok: false });
    expect(validateLoyaltyRules({ ...base, value: "-1" })).toMatchObject({ ok: false });
    expect(validateLoyaltyRules({ ...base, min: "2.5" })).toMatchObject({ ok: false });
    expect(validateLoyaltyRules({ ...base, mode: "cash" })).toMatchObject({ ok: false });
    expect(validateLoyaltyRules({ ...base, maxPercent: "0" })).toMatchObject({ ok: false });
    expect(validateLoyaltyRules({ ...base, maxPercent: "101" })).toMatchObject({ ok: false });
  });
  it("works out the example", () => {
    expect(loyaltyExample(100, 1)).toEqual({ bill: 1000, points: 10, worth: 10 });
    expect(loyaltyExample(0, -1)).toEqual({ bill: 1000, points: 10, worth: 10 });
    expect(loyaltyExample(50, 0.25)).toEqual({ bill: 500, points: 10, worth: 2.5 });
  });
});
