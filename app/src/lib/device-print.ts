/**
 * Printing choices for THIS device (counter PC, kitchen tablet). They are kept in
 * the browser because each device has its own printer. Silent printing (no dialog)
 * needs Chrome started with --kiosk-printing, or the SNA Print Helper.
 */
export type DevicePrint = {
  bills: boolean;
  stations: string[];
  /** Print the kitchen ticket (KOT) here when KOT is pressed on this device's billing screen. On unless switched off. */
  kotHere: boolean;
};

const KEY = "sna.print.v1";

export function readDevicePrint(): DevicePrint {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return { bills: false, stations: [], kotHere: true };
    const v = JSON.parse(raw) as Partial<DevicePrint>;
    return {
      bills: !!v.bills,
      stations: Array.isArray(v.stations) ? v.stations.filter((s) => typeof s === "string") : [],
      // Not chosen yet: a device that prints the kitchen's tickets from the Kitchen screen does not also
      // print them at the KOT button; any other device does.
      kotHere: typeof v.kotHere === "boolean" ? v.kotHere : !(Array.isArray(v.stations) && v.stations.length > 0),
    };
  } catch {
    return { bills: false, stations: [], kotHere: true };
  }
}

export function saveDevicePrint(v: DevicePrint) {
  try {
    localStorage.setItem(KEY, JSON.stringify(v));
  } catch {
    /* private window: settings last until the page closes */
  }
}

const PRINTED = "sna.kot.printed.v1";

/** Tickets this device already printed (kept small). */
export function printedTickets(): Set<string> {
  try {
    return new Set(JSON.parse(localStorage.getItem(PRINTED) ?? "[]") as string[]);
  } catch {
    return new Set();
  }
}

export function rememberPrinted(ids: string[]) {
  try {
    const all = [...printedTickets(), ...ids].slice(-500);
    localStorage.setItem(PRINTED, JSON.stringify(all));
  } catch {
    /* ignore */
  }
}
