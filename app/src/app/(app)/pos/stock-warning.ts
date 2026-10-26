/**
 * The amber "stock is short" strip on the billing screen (batch 3, plan 5.3). It only warns: billing is never blocked.
 * The numbers come from the database function stock_warnings; this file only words them.
 */
export type StockWarning = {
  ingredient_id: string;
  name: string;
  unit: string;
  /** What the dishes in the cart need. */
  need: number;
  /** In stock at this outlet right now (can be negative). */
  on_hand: number;
  /** on_hand - need */
  after: number;
  level: "out" | "low";
  /** Optional: the dishes in the cart that use this ingredient, so the cart can mark them with a dot. */
  product_ids?: string[];
};

/** 0.5 -> "0.5", 2 -> "2", 0.3333 -> "0.333"; never exponent notation. */
export function qtyShort(n: number): string {
  if (!Number.isFinite(n)) return "0";
  const r = Math.round(n * 1000) / 1000;
  return String(Object.is(r, -0) ? 0 : r);
}

/** One sentence for one ingredient. */
export function warningText(w: StockWarning): string {
  const u = w.unit ? ` ${w.unit}` : "";
  if (w.level === "out") {
    return w.on_hand <= 0
      ? `${w.name}: none left${w.on_hand < 0 ? ` (${qtyShort(w.on_hand)}${u} on the books)` : ""}, this order needs ${qtyShort(w.need)}${u}.`
      : `${w.name}: only ${qtyShort(w.on_hand)}${u} left, this order needs ${qtyShort(w.need)}${u}.`;
  }
  return `${w.name}: running low, ${qtyShort(w.after)}${u} will be left after this order.`;
}

/** Reads the function's answer defensively: anything unexpected gives no warnings (the strip is a courtesy, never an error). */
export function parseWarnings(raw: unknown): StockWarning[] {
  const list = raw && typeof raw === "object" ? (raw as { warnings?: unknown }).warnings : null;
  if (!Array.isArray(list)) return [];
  const out: StockWarning[] = [];
  for (const x of list) {
    if (!x || typeof x !== "object") continue;
    const w = x as Record<string, unknown>;
    const level = w.level === "out" || w.level === "low" ? w.level : null;
    if (!level || typeof w.name !== "string") continue;
    out.push({
      ingredient_id: typeof w.ingredient_id === "string" ? w.ingredient_id : w.name,
      name: w.name,
      unit: typeof w.unit === "string" ? w.unit : "",
      need: Number(w.need) || 0,
      on_hand: Number(w.on_hand) || 0,
      after: Number(w.after) || 0,
      level,
      ...(Array.isArray(w.product_ids) ? { product_ids: w.product_ids.filter((p): p is string => typeof p === "string") } : {}),
    });
  }
  // Worst first: out before low, then the biggest shortfall.
  return out.sort((a, b) => (a.level === b.level ? a.after - b.after : a.level === "out" ? -1 : 1));
}

/** The strip: the first few sentences, "and N more", and the reassurance. Empty list = no strip. */
export function stripText(list: StockWarning[], max = 3): { lines: string[]; more: number; footer: string } | null {
  if (list.length === 0) return null;
  return { lines: list.slice(0, max).map(warningText), more: Math.max(0, list.length - max), footer: "You can still bill." };
}

/** Products in the cart that have a warning on one of their ingredients (for the dot on a cart line). */
export function warnedProducts(list: StockWarning[]): Set<string> {
  const s = new Set<string>();
  for (const w of list) for (const p of w.product_ids ?? []) s.add(p);
  return s;
}
