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
  it("never returns an empty message", () => {
    expect(friendlyDbError(null)).toMatch(/try again/);
    expect(friendlyDbError({ message: "" })).toMatch(/try again/);
  });
});
