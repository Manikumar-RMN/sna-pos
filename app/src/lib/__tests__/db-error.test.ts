import { describe, expect, it } from "vitest";
import { friendlyDbError } from "../db-error";

describe("friendlyDbError", () => {
  it("passes on the plain messages the database functions raise on purpose", () => {
    expect(friendlyDbError({ message: "Enter the guest's name.", code: "P0001" })).toBe("Enter the guest's name.");
    expect(friendlyDbError({ message: "ERROR:  Choose a supplier." })).toBe("Choose a supplier.");
  });
  it("names the rule for a known table rule", () => {
    const m = 'new row for relation "ingredients" violates check constraint "ingredients_cost_per_unit_check"';
    expect(friendlyDbError({ message: m, code: "23514" })).toBe("The cost cannot be negative.");
    expect(friendlyDbError({ message: m })).toBe("The cost cannot be negative.");
    expect(friendlyDbError({ message: 'new row for relation "reservations" violates check constraint "reservations_party_size_check"' })).toMatch(/1 to 200/);
  });
  it("uses a general sentence for a rule it does not know, never the raw text", () => {
    const out = friendlyDbError({ message: 'new row for relation "x" violates check constraint "x_weird_check"', code: "23514" });
    expect(out).not.toMatch(/relation|constraint/);
    expect(friendlyDbError({ message: 'duplicate key value violates unique constraint "x_key"', code: "23505" })).toBe("That already exists.");
    expect(friendlyDbError({ message: 'invalid input syntax for type uuid: "abc"', code: "22P02" })).toMatch(/format/);
  });
  it("says plainly when the database refuses a person", () => {
    const rls = 'new row violates row-level security policy for table "products"';
    expect(friendlyDbError({ message: rls, code: "42501" })).toBe("You do not have permission to do that.");
    expect(friendlyDbError({ message: rls })).toBe("You do not have permission to do that.");
    expect(friendlyDbError({ message: "permission denied for table orders" })).toBe("You do not have permission to do that.");
    expect(friendlyDbError({ message: "anything", code: "42501" })).toBe("You do not have permission to do that.");
    expect(friendlyDbError({ message: rls, code: "42501" })).not.toMatch(/products|policy|row/);
  });
  it("asks to sign in again when the session has ended", () => {
    expect(friendlyDbError({ message: "JWT expired", code: "PGRST301" })).toBe("Please sign in again.");
    expect(friendlyDbError({ message: "JWT expired" })).toBe("Please sign in again.");
  });
  it("says so when the server cannot be reached", () => {
    expect(friendlyDbError({ message: "TypeError: fetch failed" })).toBe("Could not reach the server. Check the internet connection.");
    expect(friendlyDbError({ message: "fetch failed" })).toBe("Could not reach the server. Check the internet connection.");
  });
  it("never replaces a message our own functions raise on purpose", () => {
    expect(friendlyDbError({ message: "Bill BILL26-0007 is already paid. Use a refund.", code: "P0001" })).toBe("Bill BILL26-0007 is already paid. Use a refund.");
    expect(friendlyDbError({ message: "You do not have the right to set prices.", code: "P0001" })).toBe("You do not have the right to set prices.");
    expect(friendlyDbError({ message: "Not allowed (order.discount).", code: "P0001" })).toBe("Not allowed (order.discount).");
  });
  it("never returns an empty message", () => {
    expect(friendlyDbError(null)).toMatch(/try again/);
    expect(friendlyDbError({ message: "" })).toMatch(/try again/);
  });
});
