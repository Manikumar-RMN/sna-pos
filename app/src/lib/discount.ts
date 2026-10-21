/**
 * Reads what a person typed in a Discount box: an amount ("50", "9.95") or a percent ("10%").
 * A percent is turned into an amount on the subtotal, rounded to 2 decimals (half up).
 * The amount is never more than the subtotal. The server only ever receives the amount.
 */
export type DiscountInput = { ok: true; amount: number; percent: number | null } | { ok: false; message: string };

export const DISCOUNT_HELP = "Type an amount like 50, or a percent like 10%.";
export const PERCENT_HELP = "A percent must be more than 0 and not more than 100, for example 10%.";

const NUMBER = /^(\d+(\.\d*)?|\.\d+)$/;

export function parseDiscountInput(text: string, subtotal: number): DiscountInput {
  const raw = String(text ?? "").trim();
  if (raw === "") return { ok: true, amount: 0, percent: null };
  const base = Number.isFinite(subtotal) && subtotal > 0 ? subtotal : 0;
  const baseCents = Math.round(base * 100);

  if (raw.endsWith("%")) {
    const body = raw.slice(0, -1).trim();
    if (!NUMBER.test(body)) return { ok: false, message: PERCENT_HELP };
    const percent = Number(body);
    if (!(percent > 0) || percent > 100) return { ok: false, message: PERCENT_HELP };
    // Whole cents, half up. The tiny extra guards against 0.4999999 style float errors.
    const cents = Math.floor((baseCents * percent) / 100 + 0.5 + 1e-9);
    return { ok: true, amount: Math.min(cents, baseCents) / 100, percent };
  }

  if (raw.startsWith("-")) return { ok: false, message: "A discount cannot be negative." };
  if (!NUMBER.test(raw)) return { ok: false, message: DISCOUNT_HELP };
  const cents = Math.floor(Number(raw) * 100 + 0.5 + 1e-9);
  return { ok: true, amount: Math.min(cents, baseCents) / 100, percent: null };
}
