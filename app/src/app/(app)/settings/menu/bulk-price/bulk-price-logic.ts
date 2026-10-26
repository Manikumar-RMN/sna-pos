/**
 * Small, pure helpers for the bulk price screen. NO price maths lives here: the database computes every new price
 * (rounding included) in bulk_price_preview / bulk_price_apply, so the preview is exactly what is applied.
 * These helpers only check what the person typed, build the scope sent to the database and summarise the preview.
 */
export type BulkMode = "percent" | "amount";
export const ROUNDINGS = [1, 0.5, 0.01] as const;
export type Rounding = (typeof ROUNDINGS)[number];

export type BulkScope = { all?: boolean; category_ids?: string[]; product_ids?: string[] };

export type PreviewLine = {
  product_id: string;
  name: string;
  category: string;
  scope: "base" | "branch";
  branch_id: string | null;
  branch: string | null;
  old_price: number;
  new_price: number;
  /** Set by the database when the new price is not allowed: below zero, or above the largest price. */
  problem?: "below_zero" | "too_high" | null;
};

export type Preview = {
  lines: PreviewLine[];
  total_lines: number;
  base_lines: number;
  branch_lines: number;
  truncated: boolean;
  include_branch: boolean;
  /** From migration 140 (missing before it: treated as none). Lines that would go below zero / above the largest price. */
  below_zero_lines?: number;
  too_high_lines?: number;
  invalid_lines?: number;
  invalid_items?: number;
  can_apply?: boolean;
};

export type HistoryRow = {
  id: string;
  created_at: string;
  by: string | null;
  mode: BulkMode;
  value: number;
  rounding: number;
  include_branch: boolean;
  reason: string;
  status: "applied" | "undone";
  lines: number;
  undone_at: string | null;
  undone_by: string | null;
  restored: number | null;
  skipped: number | null;
};

/** "12" / "12.5" / "-5" / "12,5" -> number, or null when it is not a plain number. */
export function parseValue(text: string): number | null {
  const t = text.trim().replace(",", ".");
  if (!/^[+-]?\d+(\.\d+)?$/.test(t)) return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

/** The scope the database expects, or null when nothing is chosen. */
export function buildScope(input: { all: boolean; categoryIds: string[]; productIds: string[] }): BulkScope | null {
  if (input.all) return { all: true };
  const category_ids = [...new Set(input.categoryIds)];
  const product_ids = [...new Set(input.productIds)];
  if (category_ids.length === 0 && product_ids.length === 0) return null;
  const scope: BulkScope = {};
  if (category_ids.length > 0) scope.category_ids = category_ids;
  if (product_ids.length > 0) scope.product_ids = product_ids;
  return scope;
}

/** Same limits as the database, so the person hears about a typo before the round trip. */
export function checkInput(input: { mode: BulkMode; valueText: string; scope: BulkScope | null }): { ok: true; value: number } | { ok: false; error: string } {
  const value = parseValue(input.valueText);
  if (value === null) return { ok: false, error: "Type the change as a number, for example 10 or -5." };
  if (value === 0) return { ok: false, error: "Enter how much to change the prices by." };
  if (input.mode === "percent" && (value < -90 || value > 500)) return { ok: false, error: "A percentage change must be between -90 and 500." };
  if (input.mode === "amount" && Math.abs(value) > 1_000_000) return { ok: false, error: "Enter a sensible amount." };
  if (!input.scope) return { ok: false, error: "Choose which dishes to change." };
  return { ok: true, value };
}

/** "+10%" / "-5%" / "+2.50" / "-1" for a heading. */
export function describeChange(mode: BulkMode, value: number): string {
  const sign = value > 0 ? "+" : value < 0 ? "-" : "";
  const abs = Math.abs(value);
  const text = mode === "percent" ? `${trim(abs)}%` : abs.toFixed(Number.isInteger(abs) ? 0 : 2);
  return `${sign}${text}`;
}

function trim(n: number): string {
  return String(Number(n.toFixed(4)));
}

export function summarize(preview: Preview): { items: number; up: number; down: number; outletPrices: number; hiddenRows: number; belowZero: number; tooHigh: number; invalid: number; canApply: boolean } {
  const items = new Set(preview.lines.filter((l) => l.scope === "base").map((l) => l.product_id)).size;
  let up = 0;
  let down = 0;
  for (const l of preview.lines) {
    if (l.new_price > l.old_price) up += 1;
    else if (l.new_price < l.old_price) down += 1;
  }
  // The database counts every flagged line (the list on screen may be cut); older databases send no counts, so count what is shown.
  const shownBelow = preview.lines.filter((l) => l.problem === "below_zero").length;
  const shownHigh = preview.lines.filter((l) => l.problem === "too_high").length;
  const belowZero = Math.max(Number(preview.below_zero_lines ?? 0), shownBelow);
  const tooHigh = Math.max(Number(preview.too_high_lines ?? 0), shownHigh);
  const invalid = belowZero + tooHigh;
  return {
    items,
    up,
    down,
    outletPrices: preview.branch_lines,
    hiddenRows: Math.max(0, preview.total_lines - preview.lines.length),
    belowZero,
    tooHigh,
    invalid,
    canApply: preview.total_lines > 0 && invalid === 0 && preview.can_apply !== false,
  };
}

/** The sentence shown above the list when some new prices are not allowed (the database refuses the whole batch). */
export function problemText(s: { belowZero: number; tooHigh: number; invalid: number }, maxPrice = 10_000_000): string | null {
  if (s.invalid === 0) return null;
  const parts: string[] = [];
  if (s.belowZero > 0) parts.push(`${s.belowZero} ${s.belowZero === 1 ? "price would" : "prices would"} go below zero`);
  if (s.tooHigh > 0) parts.push(`${s.tooHigh} ${s.tooHigh === 1 ? "price would" : "prices would"} go above ${maxPrice}`);
  return `${parts.join(" and ")}. Nothing can be changed until that is fixed: use a smaller reduction, or leave those dishes out. They are listed first, in red.`;
}

/** A sentence for the history list. */
export function historyTitle(h: Pick<HistoryRow, "mode" | "value" | "lines">): string {
  return `${describeChange(h.mode, Number(h.value))} on ${h.lines} ${h.lines === 1 ? "price" : "prices"}`;
}

/** Which dishes belong to a category and all its sub-categories (to tick a whole category group). */
export function descendantIds(categories: { id: string; parent_id: string | null }[], rootId: string): string[] {
  const out = [rootId];
  for (let i = 0; i < out.length; i += 1) {
    for (const c of categories) if (c.parent_id === out[i] && !out.includes(c.id)) out.push(c.id);
  }
  return out;
}
