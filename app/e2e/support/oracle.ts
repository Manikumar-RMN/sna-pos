import { calcBill, type CalcInput } from "../../src/lib/calc-bill";
import { rpc } from "./db";
import type { World } from "./world";

/** The app's own offline calculator, fed with the tax rules the database reports for this restaurant. */
export async function oracle(w: World, cart: Record<string, number>, opts: { discount?: number; prices?: Record<string, number>; serviceCharge?: { percent: number; taxable?: boolean } } = {}) {
  const snap = await rpc(w.manager.auth, "offline_snapshot", ["00000000-0000-4000-8000-0000000000aa"]);
  const byId = new Map<string, any>(snap.menu.map((m: any) => [m.id, m]));
  const input: CalcInput = {
    lines: Object.entries(cart).map(([k, qty], i) => {
      const m = byId.get(w.products[k].id);
      return { key: i + 1, price: opts.prices?.[k] ?? m.price, qty, inclusive: m.inclusive, comps: m.comps };
    }),
    discount: opts.discount ?? 0,
    sc_percent: opts.serviceCharge?.percent ?? 0,
    sc_taxable: opts.serviceCharge?.taxable ?? false,
    rounding: snap.settings.rounding,
  };
  return calcBill(input);
}

export async function expectError(p: Promise<unknown>, re: RegExp) {
  let err: Error | null = null;
  try { await p; } catch (e) { err = e as Error; }
  if (!err) throw new Error(`Expected an error matching ${re}, but the call succeeded`);
  if (!re.test(err.message)) throw new Error(`Expected an error matching ${re}, got: ${err.message}`);
}
