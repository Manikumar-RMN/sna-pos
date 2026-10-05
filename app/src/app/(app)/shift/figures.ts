import { money } from "@/lib/format";

/**
 * A closed shift keeps the report it had when it closed. Bills voided after
 * that are counted beside it. Reports saved before this existed do not carry
 * the two figures: missing means none.
 */
export type LateVoids = { voided_after_close?: number | null; voided_after_close_value?: number | null };

/** The sentence shown on a closed shift that had bills voided afterwards, or null when there were none. */
export function voidedAfterCloseNote(f: LateVoids, currency: string): string | null {
  const n = Number(f.voided_after_close ?? 0);
  if (!(n > 0)) return null;
  const worth = money(Number(f.voided_after_close_value ?? 0), currency);
  // The figure counts card and unpaid bills too, so it does not say that cash went out.
  return `${n} bill${n === 1 ? "" : "s"} worth ${worth} ${n === 1 ? "was" : "were"} voided after this shift closed. Any cash given back came out of the drawer that was open at the time.`;
}

/**
 * A closed shift only: bills that were unpaid when it closed and were paid in a
 * later shift. Those bills are that later shift's sale. Older reports do not
 * carry the two figures: missing means none.
 */
export type PaidLater = { paid_later?: number | null; paid_later_value?: number | null };

/** The sentence shown on a closed shift whose unpaid bills were paid in a later shift, or null when there were none. */
export function paidLaterNote(f: PaidLater, currency: string): string | null {
  const n = Number(f.paid_later ?? 0);
  if (!(n > 0)) return null;
  const worth = money(Number(f.paid_later_value ?? 0), currency);
  return n === 1
    ? `1 bill worth ${worth} was still unpaid when this shift closed and was paid later. It is counted in the shift that took the money.`
    : `${n} bills worth ${worth} were still unpaid when this shift closed and were paid later. They are counted in the shift that took the money.`;
}
