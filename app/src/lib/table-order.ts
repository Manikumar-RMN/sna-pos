/** Table numbers in the order people count them: 1, 2 … 10, 11, then A1, A2 … (not 1, 10, 11, 2). */
export function byTableNumber<T extends { table_number: string }>(a: T, b: T): number {
  return a.table_number.localeCompare(b.table_number, "en", { numeric: true, sensitivity: "base" });
}
