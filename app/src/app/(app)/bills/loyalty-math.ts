/**
 * Pure helpers for the bill screen: the discount pool and the points a guest may use as a discount.
 * Display and input limits only. The database (redeem_points_discount, calc_bill) is the authority and
 * recalculates everything; these numbers just stop people typing something the server will refuse.
 */

/** Loyalty figures for the receipt. Same shape as ReceiptData.loyalty (defined by WS-A1 in pos/receipt-view.tsx). */
export type ReceiptLoyalty = { earned: number; redeemed: number; balance: number };

export type PoolLine = { amount: number; blocked?: boolean };

const cents = (n: number) => Math.round(n * 100);

/** Sum of the line amounts that can take a discount (lines marked "do not discount" are left out). */
export function discountPool(lines: PoolLine[]): number {
  return lines.reduce((s, l) => (l.blocked ? s : s + cents(l.amount)), 0) / 100;
}

export type RedeemLimits = {
  balance: number;
  pointValue: number;
  minRedeem: number;
  /** Highest share (1..100) of the discountable pool that points may pay. */
  maxPercent: number;
  pool: number;
  /** Discount typed by hand on the bill (it is taken from the pool first). */
  manualDiscount: number;
  /** Amount still to pay on the bill. */
  due: number;
};

/** The most points that can be used on this bill now (whole points; 0 when none can). */
export function maxRedeemablePoints(x: RedeemLimits): number {
  if (!(x.pointValue > 0)) return 0;
  const room = Math.min(
    Math.max(0, (cents(x.pool) * x.maxPercent) / 100 - cents(x.manualDiscount)),
    Math.max(0, cents(x.pool) - cents(x.manualDiscount)),
    cents(x.due),
  );
  const byBill = Math.floor(room / 100 / x.pointValue + 1e-9);
  const max = Math.min(Math.floor(x.balance), byBill);
  return max >= Math.max(1, x.minRedeem) ? max : 0;
}

/** Rupees off for a number of points. */
export function pointsToAmount(points: number, pointValue: number): number {
  return Math.round(points * pointValue * 100) / 100;
}

/** Why points cannot be used now, in plain words; null when they can. */
export function redeemBlockedReason(x: RedeemLimits & { senior: boolean; hasPayments: boolean }): string | null {
  if (x.senior) return "A senior citizen / PWD discount is on this bill, so points cannot be used.";
  if (x.hasPayments) return "This bill already has a payment, so points cannot be used.";
  if (x.balance < Math.max(1, x.minRedeem)) return `The guest needs at least ${Math.max(1, x.minRedeem)} points to use them.`;
  if (x.pool <= 0) return "None of these items can be discounted.";
  if (maxRedeemablePoints(x) === 0) return "These points are worth too little for this bill.";
  return null;
}

/** Reads the loyalty part of orders.calc_params. */
export function appliedLoyalty(calcParams: unknown): { points: number; discount: number } {
  const cp = (calcParams ?? {}) as { loyalty_points?: number | string; loyalty_discount?: number | string };
  const points = Number(cp.loyalty_points ?? 0);
  const discount = Number(cp.loyalty_discount ?? 0);
  return { points: points > 0 ? points : 0, discount: discount > 0 ? discount : 0 };
}

/** Receipt figures from this bill's ledger rows (earned = earn minus reversals; redeemed = points taken minus any given back). */
export function receiptLoyalty(rows: { kind: string; points: number | string }[], balance: number): ReceiptLoyalty {
  let earned = 0;
  let net = 0;
  for (const r of rows) {
    const p = Number(r.points);
    if (r.kind === "earn" || r.kind === "reverse") earned += p;
    else if (r.kind === "redeem" || r.kind === "adjust") net += p;
  }
  return { earned: Math.max(0, earned), redeemed: Math.max(0, -net), balance };
}


/** "Regular - 7 visits, 120 points" (points only when the outlet uses loyalty). */
export function regularChipText(g: { visits: number; points: number }, showPoints: boolean): string | null {
  if (g.visits < 1) return null;
  const visits = `${g.visits} ${g.visits === 1 ? "visit" : "visits"}`;
  const label = g.visits >= 2 ? "Regular" : "Returning";
  return `${label} - ${visits}${showPoints && g.points > 0 ? `, ${g.points} points` : ""}`;
}
