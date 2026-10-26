// Tip entry helpers. A tip is a MEMO: it is recorded next to the payment (migration 133) and never counted in the bill,
// the payment, shift cash, day close or tax. Nothing here works out money that the database owns; the percent chips only
// suggest a number to type into the box, and the server stores exactly what is sent.

/** Largest tip the till accepts (the database refuses anything above 99,999,999). */
export const MAX_TIP = 99999999;

export type TipParse = { ok: true; value: number } | { ok: false; error: string };

/** "" -> 0 (no tip). Up to two decimals with a point; no signs, no exponent, no commas (1,25 must never be read as 125). */
export function parseTip(text: string): TipParse {
  const t = text.trim();
  if (t === "") return { ok: true, value: 0 };
  if (!/^\d{1,8}(\.\d{0,2})?$/.test(t)) return { ok: false, error: "Enter the tip as an amount, for example 50 or 12.50." };
  const value = Math.round(Number(t) * 100) / 100;
  if (value > MAX_TIP) return { ok: false, error: "That tip is too large." };
  return { ok: true, value };
}

/** A suggestion for the box: pct percent of base, rounded to the nearest whole unit (50 not 47.35). 0 when it cannot be worked out. */
export function suggestTip(base: number, pct: number): number {
  if (!Number.isFinite(base) || !Number.isFinite(pct) || base <= 0 || pct <= 0) return 0;
  return Math.round((base * pct) / 100);
}

/** The text to put in the box for a suggestion ("" when there is none). */
export function tipText(amount: number): string {
  return amount > 0 ? String(amount) : "";
}

/** What payBill should send: the number, or undefined (omit) when there is no tip. A bad entry never reaches the server. */
export function tipForRequest(text: string): number | undefined {
  const r = parseTip(text);
  return r.ok && r.value > 0 ? r.value : undefined;
}

/** null when the entry is fine (including empty); otherwise the sentence to show. Use it to disable the pay button. */
export function tipError(text: string): string | null {
  const r = parseTip(text);
  return r.ok ? null : r.error;
}
