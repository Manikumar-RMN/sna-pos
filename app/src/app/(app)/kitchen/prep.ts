/**
 * Prep time on the kitchen board (batch 3, feature C).
 *
 * products.prep_minutes (1..240, null = not set) is the dish's preparation time; a size row inherits its dish
 * (coalesce(size, dish)). A kitchen ticket is late when it is older than the LONGEST prep on it plus the grace;
 * with no prep time anywhere the old fixed 15 minutes apply. Never affects billing.
 */
import { KOT_DELAYED_MIN, PREP_GRACE_MIN } from "@/lib/table-status";

/** True when a waiting ticket of `ageMin` minutes is late. Same rule as the floor (table-status.ts / floor_status). */
export function kitchenLate(ageMin: number, prepMin?: number | null): boolean {
  const p = prepMin == null ? NaN : Number(prepMin);
  if (Number.isFinite(p) && p > 0) return ageMin > p + PREP_GRACE_MIN;
  return ageMin >= KOT_DELAYED_MIN; // the board always used ">= 15"
}

type Loose = {
  from: (t: string) => {
    select: (c: string) => { in: (col: string, v: string[]) => PromiseLike<{ data: unknown; error: unknown }> };
  };
};
type Prod = { id: string; parent_id: string | null; prep_minutes: number | null };

/** Prep minutes per order item id (missing = not set). Any failure (column not migrated yet) gives an empty map. */
export async function prepMinutesByOrderItem(client: unknown, orderItemIds: string[]): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  const ids = [...new Set(orderItemIds)];
  if (!ids.length) return out;
  try {
    const db = client as Loose;
    const oi = await db.from("order_items").select("id, product_id").in("id", ids);
    if (oi.error || !Array.isArray(oi.data)) return out;
    const prodOf = new Map((oi.data as { id: string; product_id: string }[]).map((r) => [r.id, r.product_id]));
    const pids = [...new Set(prodOf.values())];
    if (!pids.length) return out;
    const pr = await db.from("products").select("id, parent_id, prep_minutes").in("id", pids);
    if (pr.error || !Array.isArray(pr.data)) return out;
    const prods = new Map((pr.data as Prod[]).map((p) => [p.id, p]));
    // Sizes with no prep of their own look at the dish.
    const parentIds = [...new Set([...prods.values()].filter((p) => p.prep_minutes == null && p.parent_id).map((p) => p.parent_id as string))];
    const parents = new Map<string, Prod>();
    if (parentIds.length) {
      const pp = await db.from("products").select("id, parent_id, prep_minutes").in("id", parentIds);
      if (!pp.error && Array.isArray(pp.data)) for (const p of pp.data as Prod[]) parents.set(p.id, p);
    }
    for (const [itemId, pid] of prodOf) {
      const p = prods.get(pid);
      if (!p) continue;
      const v = p.prep_minutes ?? (p.parent_id ? parents.get(p.parent_id)?.prep_minutes : null) ?? null;
      if (v != null && Number(v) > 0) out.set(itemId, Number(v));
    }
  } catch {
    return new Map();
  }
  return out;
}
