/**
 * Stock helpers shared by the Stock screens and the dashboard card. Pure functions only (no database, no React),
 * so they can be unit-tested. The database is the authority on every number; this file only formats and checks.
 */

export const STOCK_UNITS = ["kg", "g", "l", "ml", "pcs", "pack"] as const;

/** Reasons the database accepts on a wastage / adjustment line (stock_movements.reason). Keep in step with MIG/143. */
export const STOCK_REASONS = ["spoilage", "expired", "spill", "breakage", "staff_meal", "sample", "theft", "count_correction", "other"] as const;
export type StockReason = (typeof STOCK_REASONS)[number];

export const REASON_LABEL: Record<StockReason, string> = {
  spoilage: "Spoiled",
  expired: "Expired",
  spill: "Spilled",
  breakage: "Broken",
  staff_meal: "Staff meal",
  sample: "Sample / tasting",
  theft: "Missing / theft",
  count_correction: "Stock count correction",
  other: "Other",
};

/** Reasons a person can pick by hand. "Stock count correction" is written only by the count sheet. */
export const MANUAL_REASONS: StockReason[] = STOCK_REASONS.filter((r) => r !== "count_correction");

export function reasonLabel(reason: string | null | undefined): string {
  if (!reason) return "—";
  return REASON_LABEL[reason as StockReason] ?? reason;
}

export type AdjustKind = "wastage" | "adjust_in" | "adjust_out";
export const ADJUST_KIND_LABEL: Record<AdjustKind, string> = {
  wastage: "Wastage (thrown away)",
  adjust_in: "Add to stock (found extra)",
  adjust_out: "Take off stock (lost / correction)",
};

export type StockStatus = "ok" | "low" | "out" | "negative";

/** Stock level -> status. Matches the database rule: out when 0 or less, low when at or under a reorder level above 0. */
export function stockStatus(stock: number, reorder: number): StockStatus {
  const s = Number(stock);
  const r = Number(reorder);
  if (s < 0) return "negative";
  if (s === 0) return "out";
  if (r > 0 && s <= r) return "low";
  return "ok";
}

export const STATUS_LABEL: Record<StockStatus, string> = { ok: "In stock", low: "Low", out: "Out", negative: "Negative" };

/** Order for "worst first". */
export const STATUS_RANK: Record<StockStatus, number> = { negative: 0, out: 1, low: 2, ok: 3 };

export function isAttention(status: StockStatus): boolean {
  return status !== "ok";
}

/** Quantity text without float noise: 0.30000000000000004 -> "0.3". */
export function fmtQty(x: number | string | null | undefined): string {
  const v = Number(x ?? 0);
  if (!Number.isFinite(v)) return "0";
  return (Math.round(v * 1000) / 1000).toString();
}

/** Accepts "2", "2.5", " 2,5 " (comma as decimal). Returns null for blank or not a number. */
export function parseQty(text: string | null | undefined): number | null {
  const t = String(text ?? "").trim().replace(",", ".");
  if (t === "") return null;
  if (!/^\d*\.?\d+$|^\d+\.$/.test(t)) return null;
  const v = Number(t);
  return Number.isFinite(v) ? v : null;
}

export type IngredientLite = { id: string; name: string; unit: string; cost: number; reorder: number; stock: number; category?: string | null };

/** Ingredient id → its buying unit (e.g. kg) and how many stock units it holds (1000 g). Only ingredients that have one are listed. */
export type BuyUnits = Record<string, { unit: string; factor: number }>;

// ---------- Quick stock-in ----------

export type StockInRow = { ingredient_id: string; qty: string; cost: string; /** Typed in the buying unit (kg) instead of the stock unit (g). */ buy?: boolean };
export type StockInLine = { ingredient_id: string; qty: number; unit_cost: number; unit?: "purchase" };

/**
 * Turns the form rows into the lines sent to the database. Blank rows (no ingredient and no quantity) are skipped;
 * a half-filled row is an error so nothing is silently dropped.
 */
export function buildStockInLines(rows: StockInRow[]): { ok: true; lines: StockInLine[] } | { ok: false; error: string } {
  const lines: StockInLine[] = [];
  const seen = new Set<string>();
  for (const r of rows) {
    const blank = !r.ingredient_id && r.qty.trim() === "";
    if (blank) continue;
    if (!r.ingredient_id) return { ok: false, error: "Choose the ingredient on every line." };
    const qty = parseQty(r.qty);
    if (qty == null || qty <= 0) return { ok: false, error: "Enter a quantity above zero on every line." };
    const cost = r.cost.trim() === "" ? 0 : parseQty(r.cost);
    if (cost == null) return { ok: false, error: "A price per unit must be a number (or leave it empty)." };
    if (seen.has(r.ingredient_id)) return { ok: false, error: "An ingredient is listed twice. Add the two quantities together." };
    seen.add(r.ingredient_id);
    lines.push(r.buy ? { ingredient_id: r.ingredient_id, qty, unit_cost: cost, unit: "purchase" } : { ingredient_id: r.ingredient_id, qty, unit_cost: cost });
  }
  if (lines.length === 0) return { ok: false, error: "Add at least one ingredient." };
  return { ok: true, lines };
}

export function stockInTotal(lines: StockInLine[]): number {
  return Math.round(lines.reduce((a, l) => a + l.qty * l.unit_cost, 0) * 100) / 100;
}

// ---------- Stock count ----------

export type CountLine = { ingredient_id: string; counted: number };

export type CountRow = { id: string; name: string; unit: string; cost: number; expected: number; counted: string };

/** Difference and its value for one row; null while the row is blank or invalid (a blank row is "not counted"). */
export function countDiff(row: Pick<CountRow, "expected" | "cost" | "counted">): { counted: number; diff: number; value: number } | null {
  const counted = parseQty(row.counted);
  if (counted == null) return null;
  const diff = Math.round((counted - Number(row.expected)) * 1000) / 1000;
  const value = Math.round(diff * Number(row.cost) * 100) / 100;
  return { counted, diff, value };
}

/** Rows with an invalid (not blank, not a number) entry. */
export function invalidCountRows(rows: Pick<CountRow, "id" | "counted">[]): string[] {
  return rows.filter((r) => r.counted.trim() !== "" && parseQty(r.counted) == null).map((r) => r.id);
}

export function buildCountLines(rows: CountRow[]): CountLine[] {
  const out: CountLine[] = [];
  for (const r of rows) {
    const c = parseQty(r.counted);
    if (c != null) out.push({ ingredient_id: r.id, counted: c });
  }
  return out;
}

export function countSummary(rows: CountRow[]): { counted: number; changed: number; variance: number } {
  let counted = 0;
  let changed = 0;
  let variance = 0;
  for (const r of rows) {
    const d = countDiff(r);
    if (!d) continue;
    counted++;
    if (d.diff !== 0) changed++;
    variance += d.value;
  }
  return { counted, changed, variance: Math.round(variance * 100) / 100 };
}

// ---------- Recipes ----------

export type RecipeEditRow = { ingredient_id: string; qty: string };

/** Cost of one portion at today's ingredient cost, plus food cost % of the price (null when price is 0). */
export function recipeCost(rows: RecipeEditRow[], ingredients: Pick<IngredientLite, "id" | "cost">[], price: number): { cost: number; pct: number | null } {
  const byId = new Map(ingredients.map((i) => [i.id, Number(i.cost)]));
  let cost = 0;
  for (const r of rows) {
    const q = parseQty(r.qty);
    if (!r.ingredient_id || q == null || q <= 0) continue;
    cost += q * (byId.get(r.ingredient_id) ?? 0);
  }
  cost = Math.round(cost * 100) / 100;
  const pct = price > 0 ? Math.round((cost / price) * 1000) / 10 : null;
  return { cost, pct };
}

/** Food cost % colour: above 100 is impossible in a real kitchen and almost always a g / kg mix-up. */
export function foodCostTone(pct: number | null): "none" | "ok" | "high" | "absurd" {
  if (pct == null) return "none";
  if (pct > 100) return "absurd";
  if (pct > 35) return "high";
  return "ok";
}

/**
 * Units are never converted: the recipe quantity is in the ingredient's own unit. A large number of kg or litres in one
 * portion is nearly always grams typed against a kg ingredient, so the form warns. Returns the warning text or null.
 */
export function unitMismatchWarning(unit: string, qty: number | null): string | null {
  if (qty == null || qty <= 0) return null;
  if ((unit === "kg" || unit === "l") && qty >= 20) {
    return `${fmtQty(qty)} ${unit} in one portion looks too much. Stock is kept in ${unit}, so 250 g is written 0.25.`;
  }
  if ((unit === "g" || unit === "ml") && qty < 1) {
    return `${fmtQty(qty)} ${unit} is very small. Stock is kept in ${unit}, not in ${unit === "g" ? "kg" : "litres"}.`;
  }
  return null;
}

export const UNIT_HINT = "Quantities are in the ingredient's own unit. If stock is kept in kg, write 250 g as 0.25. If it is kept in g, write 250.";

// ---------- Low stock card (dashboard) ----------

export type LowStockItem = { id: string; name: string; unit: string; on_hand: number; reorder_level: number; status: StockStatus };
export type LowStock = { items: LowStockItem[]; out: number; low: number; negative: number };

/** Reads the low_stock_items() result ({items:[{ingredient_id,name,unit,on_hand,reorder_level,status}], counts:{out,low,negative}}) defensively: unknown or missing parts become empty. */
export function parseLowStock(raw: unknown): LowStock {
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
  const list = (Array.isArray(o.items) ? o.items : Array.isArray(o.rows) ? o.rows : []) as Record<string, unknown>[];
  const items: LowStockItem[] = list.map((r) => {
    const onHand = Number(r.on_hand ?? r.stock ?? 0);
    const reorder = Number(r.reorder_level ?? r.reorder ?? 0);
    // low_stock_items (migration 143) sends its own status: 'negative' | 'out' | 'low'. Use it, else work it out.
    const dbStatus = r.status === "negative" || r.status === "out" || r.status === "low" ? (r.status as StockStatus) : null;
    return {
      id: String(r.ingredient_id ?? r.id ?? ""),
      name: String(r.name ?? ""),
      unit: String(r.unit ?? ""),
      on_hand: onHand,
      reorder_level: reorder,
      status: dbStatus ?? stockStatus(onHand, reorder),
    };
  });
  const c = (o.counts && typeof o.counts === "object" ? o.counts : {}) as Record<string, unknown>;
  const num = (v: unknown, fallback: number) => (v == null || !Number.isFinite(Number(v)) ? fallback : Number(v));
  return {
    items,
    out: num(c.out, items.filter((i) => i.status === "out").length),
    low: num(c.low, items.filter((i) => i.status === "low").length),
    negative: num(c.negative, items.filter((i) => i.status === "negative").length),
  };
}
