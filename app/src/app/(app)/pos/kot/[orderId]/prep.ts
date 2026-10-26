/**
 * Preparation time on a kitchen ticket (batch 3): the longest prep time among its items, so the slip says "~12 min".
 * A size has its own value, or its dish's when it has none. No item with a time set: null (nothing is printed).
 * Never affects billing.
 */
export type PrepProduct = { id: string; parent_id: string | null; prep_minutes: number | null };

/** One product's prep time: its own, else its dish's. */
export function prepOf(productId: string | null | undefined, byId: Map<string, PrepProduct>): number | null {
  const p = productId ? byId.get(productId) : undefined;
  if (!p) return null;
  const own = p.prep_minutes;
  if (typeof own === "number" && own > 0) return own;
  const parent = p.parent_id ? byId.get(p.parent_id) : undefined;
  return parent && typeof parent.prep_minutes === "number" && parent.prep_minutes > 0 ? parent.prep_minutes : null;
}

/** The longest prep time among these products, or null when none has one. */
export function maxPrep(productIds: (string | null | undefined)[], byId: Map<string, PrepProduct>): number | null {
  let best: number | null = null;
  for (const id of productIds) {
    const v = prepOf(id, byId);
    if (v != null && (best == null || v > best)) best = v;
  }
  return best;
}
