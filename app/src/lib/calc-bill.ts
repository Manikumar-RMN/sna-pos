/**
 * The bill calculator, line for line the same as the database's app.calc_bill.
 * Used only when the internet is down, so the counter can keep billing; the
 * server recalculates every offline bill when it syncs. A test compares this
 * file with the database on thousands of random bills.
 */
export type CalcComp = { name: string; rate: number; compound?: boolean };
export type CalcLine = {
  key: number;
  price: number;
  qty: number;
  inclusive?: boolean;
  comps: CalcComp[];
  /** The dish is marked "Do not allow discounts": it never takes a share of a bill discount (batch 3, plan 3.1). */
  no_disc?: boolean;
};
export type CalcInput = {
  lines: CalcLine[];
  discount?: number;
  /**
   * Loyalty points used as a discount before tax (plan 4.4). Applied after the manual discount, from what is
   * left of the pool. Never offline: the points balance must be checked online. Kept here so the mirror stays complete.
   */
  loyalty_discount?: number;
  sc_percent?: number;
  sc_taxable?: boolean;
  senior?: { share: number; rate?: number } | null;
  rounding?: string;
};
export type CalcTax = { name: string; rate: number; taxable: number; amount: number };
export type CalcResult = {
  lines: { key: number; subtotal: number; discount: number; senior_discount: number; net: number; service_charge: number; tax: number; tax_included: number; total: number; taxes: CalcTax[] }[];
  subtotal: number;
  /** The manual part of the bill discount that was applied (after the cap at the pool). */
  discount: number;
  /** The loyalty-points part that was applied (0 when none). Total taken off before tax = discount + loyalty_discount. */
  loyalty_discount: number;
  /** Sum of the line subtotals of lines that may be discounted: the most a discount can be. */
  discountable_subtotal: number;
  senior_discount: number;
  tax_exempt_amount: number;
  exempt_sales: number;
  service_charge: number;
  tax_total: number;
  tax_included: number;
  net_sales: number;
  before_round: number;
  rounding: number;
  grand_total: number;
  taxes: { name: string; rate: number; taxable: number; amount: number }[];
};

/** Money in paise / cents as whole numbers avoids floating-point drift. */
const C = (x: number) => Math.round(x * 100);
/** Postgres round(x, 2): half away from zero. x is in whole units (rupees), result in cents. */
function r2(x: number): number {
  const v = x * 100;
  const s = v < 0 ? -1 : 1;
  const a = Math.abs(v);
  // Guard against 1.005 → 100.49999… style representation errors.
  return s * Math.floor(a + 0.5 + 1e-9);
}

export function roundCash(amountCents: number, mode: string): number {
  const step = mode === "nearest_1" ? 100 : mode === "nearest_0_05" ? 5 : mode === "nearest_0_10" ? 10 : 0;
  if (!step) return amountCents;
  const s = amountCents < 0 ? -1 : 1;
  return s * Math.floor(Math.abs(amountCents) / step + 0.5 + 1e-9) * step;
}

export function calcBill(p: CalcInput): CalcResult {
  const lines = p.lines ?? [];
  const n = lines.length;
  const discIn = r2(p.discount ?? 0); // cents
  const loyIn = r2(p.loyalty_discount ?? 0); // cents
  const scPct = p.sc_percent ?? 0;
  const scTax = !!p.sc_taxable;
  const share = p.senior?.share ?? 0;
  const sPct = p.senior?.rate ?? 20;
  const rmode = p.rounding ?? "none";
  if (discIn < 0 || loyIn < 0) throw new Error("A discount cannot be negative.");
  if (share < 0 || share > 1) throw new Error("The senior citizen / PWD share must be between 0 and 100%.");
  if (share > 0 && discIn > 0) throw new Error("A senior citizen / PWD discount cannot be combined with another discount.");
  if (share > 0 && loyIn > 0) throw new Error("Loyalty points cannot be used on a senior citizen / PWD bill.");

  // Pass 1: subtotals, and the pool a discount may come from (lines not marked "no discount").
  const subs: number[] = [];
  const elig: boolean[] = [];
  let subtotal = 0;
  let pool = 0;
  let big = -1; // the largest ELIGIBLE line (the first one when equal); -1 when no line can take a discount
  for (let i = 0; i < n; i++) {
    const sub = r2(lines[i].price * lines[i].qty);
    if (sub < 0) throw new Error("A line cannot be negative.");
    const ok = !lines[i].no_disc;
    subs.push(sub);
    elig.push(ok);
    subtotal += sub;
    if (ok) {
      pool += sub;
      if (big === -1 || sub > subs[big]) big = i;
    }
  }

  // Pass 2: the manual discount comes first, the loyalty discount from what is left of the pool; the sum is
  // spread over the eligible lines by value and the largest eligible line takes the remainder.
  const manual = Math.min(discIn, pool);
  const loyalty = Math.min(loyIn, pool - manual);
  const discount = manual + loyalty;
  const discs: number[] = [];
  let alloc = 0;
  for (let i = 0; i < n; i++) {
    if (!elig[i] || i === big || pool === 0) discs.push(0);
    else {
      const d = r2((discount * subs[i]) / pool / 100);
      discs.push(d);
      alloc += d;
    }
  }
  if (big >= 0) discs[big] = discount - alloc;

  // A small discount over many lines can leave the largest line with less than
  // nothing (every small line rounds up to 0.01). When that happens, spread it
  // again to the paisa by largest remainder: no line goes below zero or above
  // its own value, and the parts still add up exactly. Whole-number arithmetic
  // (BigInt) so that a very large bill cannot lose precision. Only eligible lines take part.
  if (big >= 0 && pool > 0 && (discs[big] < 0 || discs[big] > subs[big])) {
    const dc = BigInt(discount);
    const tc = BigInt(pool);
    const bases: number[] = [];
    const rems: bigint[] = [];
    const taken: boolean[] = [];
    let sum = 0;
    for (let i = 0; i < n; i++) {
      const prod = elig[i] ? dc * BigInt(subs[i]) : BigInt(0);
      const base = Number(prod / tc);
      bases.push(base);
      rems.push(prod % tc);
      taken.push(!elig[i]);
      sum += base;
    }
    let left = discount - sum;
    while (left > 0) {
      let best = -1;
      for (let i = 0; i < n; i++) {
        if (!taken[i] && (best === -1 || rems[i] > rems[best])) best = i;
      }
      if (best === -1) break;
      bases[best] += 1;
      taken[best] = true;
      left -= 1;
    }
    for (let i = 0; i < n; i++) discs[i] = bases[i];
  }

  const out: CalcResult["lines"] = [];
  let tDisc = 0, tSdisc = 0, tRemoved = 0, tSc = 0, tTax = 0, tIncl = 0, tExempt = 0, tNet = 0, tLines = 0;
  const taxmap = new Map<string, { name: string; rate: number; taxable: number; amount: number }>();

  for (let i = 0; i < n; i++) {
    const ln = lines[i];
    const comps = ln.comps ?? [];
    const incl = !!ln.inclusive;
    const sub = subs[i];
    const disc = discs[i];

    let f = 0;
    for (const c of comps) f = f + (c.rate / 100) * (1 + (c.compound ? f : 0));

    const sGross = r2((sub / 100) * share);
    const sNet = incl ? r2(sGross / 100 / (1 + f)) : sGross;
    const sRemoved = sGross - sNet;
    const sDisc = r2(((sNet / 100) * sPct) / 100);

    const rAmt = sub - sGross - disc;
    let net = incl ? r2(rAmt / 100 / (1 + f)) : rAmt;

    const ai: number[] = [];
    const bi: number[] = [];
    let pi = 0;
    for (const c of comps) {
      const b = net + (c.compound ? pi : 0);
      const a = r2(((b / 100) * c.rate) / 100);
      ai.push(a);
      bi.push(b);
      pi += a;
    }
    if (incl) net = rAmt - pi;

    const sc = r2((((net + sNet) / 100) * scPct) / 100);

    let ps = 0;
    const lineTaxes: CalcTax[] = [];
    comps.forEach((c, k) => {
      let bs = 0, as = 0;
      if (scTax) {
        bs = sc + (c.compound ? ps : 0);
        as = r2(((bs / 100) * c.rate) / 100);
      }
      ps += as;
      lineTaxes.push({ name: c.name, rate: c.rate, taxable: (bi[k] + bs) / 100, amount: (ai[k] + as) / 100 });
      const key = `${c.name}|${c.rate}`;
      const cur = taxmap.get(key) ?? { name: c.name, rate: c.rate, taxable: 0, amount: 0 };
      cur.taxable += bi[k] + bs;
      cur.amount += ai[k] + as;
      taxmap.set(key, cur);
    });

    const lineTax = pi + ps;
    const lineIncl = incl ? pi : 0;
    const lineTotal = (incl ? rAmt : net + pi) + (sNet - sDisc) + sc + ps;

    out.push({
      key: ln.key,
      subtotal: sub / 100,
      discount: disc / 100,
      senior_discount: sDisc / 100,
      net: (net + sNet - sDisc) / 100,
      service_charge: sc / 100,
      tax: lineTax / 100,
      tax_included: lineIncl / 100,
      total: lineTotal / 100,
      taxes: lineTaxes,
    });
    tDisc += disc; tSdisc += sDisc; tRemoved += sRemoved; tExempt += sNet;
    tSc += sc; tTax += lineTax; tIncl += lineIncl; tNet += net + sNet - sDisc; tLines += lineTotal;
  }

  const before = subtotal - tDisc - tSdisc - tRemoved + tSc + tTax - tIncl;
  if (before !== tLines) throw new Error(`Internal check failed: bill total ${before / 100} does not equal line total ${tLines / 100}.`);
  const grand = roundCash(before, rmode);

  return {
    lines: out,
    subtotal: subtotal / 100,
    discount: manual / 100,
    loyalty_discount: loyalty / 100,
    discountable_subtotal: pool / 100,
    senior_discount: tSdisc / 100,
    tax_exempt_amount: tRemoved / 100,
    exempt_sales: tExempt / 100,
    service_charge: tSc / 100,
    tax_total: tTax / 100,
    tax_included: tIncl / 100,
    net_sales: tNet / 100,
    before_round: before / 100,
    rounding: (grand - before) / 100,
    grand_total: grand / 100,
    taxes: [...taxmap.values()]
      .map((t) => ({ name: t.name, rate: t.rate, taxable: t.taxable / 100, amount: t.amount / 100 }))
      .sort((a, b) => a.rate - b.rate || a.name.localeCompare(b.name)),
  };
}

export const _cents = C;
