/**
 * The points block on a receipt: shared by the screen receipt (receipt-view.tsx) and the thermal print (rawbt.ts),
 * so the two always say the same.
 */
export type ReceiptLoyalty = { earned: number; redeemed: number; balance: number };

/** Whole points as "120", part points with two decimals. */
export function pointsText(n: number) {
  return Number.isInteger(n) ? String(n) : n.toFixed(2);
}

/** The lines of the points block, or none when there is nothing worth printing (no guest, or no points at all). */
export function loyaltyLines(l: ReceiptLoyalty | null | undefined): { label: string; value: string }[] {
  if (!l || !(l.earned > 0 || l.redeemed > 0 || l.balance > 0)) return [];
  const out: { label: string; value: string }[] = [];
  if (l.earned > 0) out.push({ label: "Points earned", value: pointsText(l.earned) });
  if (l.redeemed > 0) out.push({ label: "Points used", value: pointsText(l.redeemed) });
  out.push({ label: "Points balance", value: pointsText(l.balance) });
  return out;
}
