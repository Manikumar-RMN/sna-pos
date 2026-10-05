/**
 * How the printed bill and kitchen ticket look. The owner sets this in
 * Settings → Bill layout; the database stores only the choices that differ
 * from these defaults (branch_settings.bill_format) and drops anything it
 * does not recognise.
 */
export type BillFormat = {
  /** Paper roll width in millimetres. */
  paper: "58" | "80";
  /** Size of the text on the bill. */
  text: "small" | "normal" | "large";
  /** Size of the text on the kitchen ticket. */
  kot_text: "normal" | "large";
  /** Print the restaurant's logo at the top (when one is uploaded). */
  logo: boolean;
  /** Registered business name under the trading name. */
  legal_name: boolean;
  /** Outlet name. */
  branch: boolean;
  address: boolean;
  phone: boolean;
  /** "Cashier: name" line. */
  cashier: boolean;
  /** Guest name and phone, and the delivery address. */
  guest: boolean;
  /** A "Rate" column showing the price of one. */
  rate: boolean;
  /** Scan-to-pay QR on unpaid bills (India, when a UPI ID is set). */
  upi_qr: boolean;
  /** "Billed on SNA POS" at the bottom. */
  powered_by: boolean;
};

export const DEFAULT_BILL_FORMAT: BillFormat = {
  paper: "80",
  text: "normal",
  kot_text: "normal",
  logo: true,
  legal_name: true,
  branch: true,
  address: true,
  phone: true,
  cashier: true,
  guest: true,
  rate: false,
  upi_qr: true,
  powered_by: true,
};

/** The stored layout (possibly partial, possibly from an older version) with every choice filled in. */
export function billFormat(raw: unknown): BillFormat {
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const f: BillFormat = { ...DEFAULT_BILL_FORMAT };
  if (r.paper === "58" || r.paper === "80") f.paper = r.paper;
  if (r.text === "small" || r.text === "normal" || r.text === "large") f.text = r.text;
  if (r.kot_text === "normal" || r.kot_text === "large") f.kot_text = r.kot_text;
  for (const k of ["logo", "legal_name", "branch", "address", "phone", "cashier", "guest", "rate", "upi_qr", "powered_by"] as const) {
    if (typeof r[k] === "boolean") f[k] = r[k] as boolean;
  }
  return f;
}

/** Width of the bill on screen and on paper. 80 mm rolls print about 72 mm; 58 mm rolls about 48 mm. */
export function paperWidth(f: BillFormat): { screenPx: number; printMm: number } {
  return f.paper === "58" ? { screenPx: 218, printMm: 58 } : { screenPx: 302, printMm: 80 };
}

/** Base text size on the bill, in pixels. */
export function billTextPx(f: BillFormat): number {
  return f.text === "small" ? 10 : f.text === "large" ? 13 : 11;
}
