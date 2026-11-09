/** Small readers for the inventory report functions (their JSON is plain and flat). */
export type Row = Record<string, unknown>;
export const asObj = (v: unknown): Row => (v && typeof v === "object" && !Array.isArray(v) ? (v as Row) : {});
export const asList = (v: unknown): Row[] => (Array.isArray(v) ? v.filter((x): x is Row => !!x && typeof x === "object" && !Array.isArray(x)) : []);
export const n = (v: unknown): number => {
  const x = typeof v === "number" ? v : Number(v);
  return Number.isFinite(x) ? x : 0;
};
export const s = (v: unknown, d = ""): string => (typeof v === "string" && v ? v : d);
export const q = (v: unknown, unit?: unknown): string => {
  const x = Math.round(n(v) * 1000) / 1000;
  return unit ? `${x} ${s(unit)}` : String(x);
};
