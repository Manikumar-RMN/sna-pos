import { describe, expect, it } from "vitest";
import { addDays, fromZonedInput, localDayStartIso, todayIn, toZonedInput } from "../format";

describe("the restaurant's own time zone", () => {
  it("shows a moment as the wall clock of the zone, and reads it back to the same moment", () => {
    const iso = "2026-10-14T18:45:00.000Z";
    expect(toZonedInput(iso, "Asia/Kolkata")).toBe("2026-10-15T00:15");
    expect(toZonedInput(iso, "America/New_York")).toBe("2026-10-14T14:45");
    for (const tz of ["Asia/Kolkata", "America/New_York", "Pacific/Kiritimati", "Pacific/Pago_Pago", "Europe/London"]) {
      expect(fromZonedInput(toZonedInput(iso, tz), tz)).toBe(iso);
    }
  });
  it("a clock change does not shift the hour typed in (New York, 5 Nov 2026 01:30 happens twice; 8 Mar 2026 02:30 does not exist)", () => {
    expect(toZonedInput(fromZonedInput("2026-07-01T09:00", "America/New_York"), "America/New_York")).toBe("2026-07-01T09:00");
    expect(toZonedInput(fromZonedInput("2026-12-01T09:00", "America/New_York"), "America/New_York")).toBe("2026-12-01T09:00");
  });
  it("a local day starts at the zone's midnight", () => {
    expect(localDayStartIso("2026-10-15", "Asia/Kolkata")).toBe("2026-10-14T18:30:00.000Z");
    expect(localDayStartIso("2026-10-15", "Pacific/Kiritimati")).toBe("2026-10-14T10:00:00.000Z");
  });
  it("today and 'six days ago' are the zone's calendar days", () => {
    const t = todayIn("Pacific/Kiritimati");
    expect(addDays(t, -6) < t).toBe(true);
  });
});
