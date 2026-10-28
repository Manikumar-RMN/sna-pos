/**
 * Pure helpers for the fourth set of report pages: Stock on hand, Stock movement, Food cost %, Wastage, Customers and
 * Loyalty ledger. They read the JSON that migrations 144 and 146 return (report_stock_on_hand, report_stock_movement,
 * report_food_cost, report_wastage, report_customers, report_loyalty_ledger), safely: a missing or wrong-typed field
 * becomes 0, "" or null, never an error. Totals come from the database, not from the rows. Money that the database
 * hides (null) stays null so a page can show a dash instead of a false 0.
 */

const num = (v: unknown) => {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
};
const numOrNull = (v: unknown): number | null => {
  if (v === null || v === undefined || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};
const int = (v: unknown) => Math.max(0, Math.trunc(num(v)));
const text = (v: unknown, d = "") => (typeof v === "string" && v ? v : d);
const textOrNull = (v: unknown) => (typeof v === "string" && v ? v : null);
const list = (v: unknown): Record<string, unknown>[] =>
  Array.isArray(v) ? v.filter((x): x is Record<string, unknown> => !!x && typeof x === "object" && !Array.isArray(x)) : [];
const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});

/** First of several possible keys that is present (the database may spell a key two ways). */
const pick = (r: Record<string, unknown>, ...keys: string[]): unknown => {
  for (const k of keys) if (r[k] !== undefined && r[k] !== null) return r[k];
  return undefined;
};

export type Cap = { truncated: boolean; rowLimit: number };
const capOf = (o: Record<string, unknown>, shown: number, defaultLimit = 2000): Cap => {
  const rowLimit = int(o.row_limit) || defaultLimit;
  return { truncated: o.truncated === true || shown >= rowLimit, rowLimit };
};

// ---------- units and quantities ----------

const UNIT_LABEL: Record<string, string> = { kg: "kg", g: "g", l: "L", ml: "ml", pcs: "pcs", pack: "pack" };

/** "kg", "L", "pcs"; an unknown unit is shown as it came. */
export function unitLabel(u: string | null | undefined): string {
  const k = (u ?? "").trim().toLowerCase();
  return UNIT_LABEL[k] ?? (u ?? "");
}

/** A stock quantity for a table cell: up to 3 decimals, no trailing zeros, with its unit ("2.5 kg"). */
export function qtyText(q: number | null, unit?: string | null): string {
  if (q === null || !Number.isFinite(q)) return "—";
  const s = String(Math.round(q * 1000) / 1000);
  const u = unitLabel(unit);
  return u ? `${s} ${u}` : s;
}

/** A percentage with one decimal ("32.5%"); null is a dash. */
export function pctText(p: number | null): string {
  return p === null || !Number.isFinite(p) ? "—" : `${Math.round(p * 10) / 10}%`;
}

/** Points with a sign for the ledger: "+120", "-50", "0". */
export function signedPoints(p: number): string {
  const n = Math.round(p * 100) / 100;
  return n > 0 ? `+${n}` : String(n);
}

// ---------- stock on hand (report_stock_on_hand) ----------

export type StockStatus = "ok" | "low" | "out" | "negative";
export type StockRow = {
  branchId: string;
  outletName: string;
  ingredientId: string;
  name: string;
  category: string;
  unit: string;
  onHand: number;
  /** Cost per unit; null when the person may not see costs. */
  cost: number | null;
  /** On-hand value (negative stock counts as 0). */
  value: number | null;
  reorderLevel: number | null;
  status: StockStatus;
};
export type StockOnHand = {
  rows: StockRow[];
  totals: { value: number; items: number; low: number; out: number; negative: number };
};

export function stockStatus(v: unknown): StockStatus {
  return v === "low" || v === "out" || v === "negative" ? v : "ok";
}

export const STOCK_STATUS_LABEL: Record<StockStatus, string> = { ok: "OK", low: "Low", out: "Out", negative: "Negative" };

export function parseStockOnHand(json: unknown): StockOnHand {
  const o = obj(json);
  const t = obj(o.totals);
  const rows = list(o.rows).map((r): StockRow => ({
    branchId: text(r.branch_id),
    outletName: text(r.outlet_name, "Unknown outlet"),
    ingredientId: text(r.ingredient_id),
    name: text(r.name, "Unnamed"),
    category: text(r.category),
    unit: text(r.unit),
    onHand: num(r.on_hand),
    cost: numOrNull(r.cost),
    value: numOrNull(r.value),
    reorderLevel: numOrNull(r.reorder_level),
    status: stockStatus(r.status),
  }));
  return {
    rows,
    totals: { value: num(t.value), items: int(t.items) || rows.length, low: int(t.low), out: int(t.out), negative: int(t.negative) },
  };
}

/** Rows to show: all, or only the ones that need attention (low, out, negative). */
export function attentionOnly(rows: StockRow[]): StockRow[] {
  return rows.filter((r) => r.status !== "ok");
}

// ---------- stock movement (report_stock_movement) ----------

export type MovementSummary = {
  branchId: string;
  outletName: string;
  ingredientId: string;
  name: string;
  unit: string;
  opening: number;
  purchased: number;
  transferIn: number;
  transferOut: number;
  used: number;
  wasted: number;
  adjusted: number;
  counted: number;
  closing: number;
};
export type MovementLine = {
  businessDate: string;
  at: string | null;
  outletName: string;
  ingredient: string;
  unit: string;
  kind: string;
  qty: number;
  unitCost: number | null;
  value: number | null;
  reason: string;
  note: string;
  billNumber: string | null;
  userName: string;
};
export type StockMovementReport = {
  /** One row per outlet and ingredient (report_stock_movement.rows). */
  summary: MovementSummary[];
  /** The newest lines (report_stock_movement.details, at most row_limit of them). */
  rows: MovementLine[];
  cap: Cap;
  /** `lines` = number of ingredient rows; `movements` = every movement in the period (the list may show fewer). Values are money at cost when the movement was written. */
  totals: {
    lines: number;
    movements: number;
    purchasedValue: number;
    usedValue: number;
    wastedValue: number;
    adjustedValue: number;
    countedValue: number;
  };
};

/** Plain words for a movement kind. */
export function movementKindLabel(k: string): string {
  switch (k) {
    case "purchase":
      return "Purchase";
    case "sale":
      return "Used in sale";
    case "returned":
      return "Returned (cancel or void)";
    case "wastage":
      return "Wastage";
    case "count":
      return "Stock count";
    case "adjust":
      return "Adjustment";
    case "transfer_in":
      return "Transfer in";
    case "transfer_out":
      return "Transfer out";
    default: {
      const s = k.replace(/_/g, " ").trim();
      return s ? s.charAt(0).toUpperCase() + s.slice(1) : "Other";
    }
  }
}

export function parseStockMovement(json: unknown): StockMovementReport {
  const o = obj(json);
  const t = obj(o.totals);
  const summary = list(o.rows).map((r): MovementSummary => ({
    branchId: text(r.branch_id),
    outletName: text(r.outlet_name, "Unknown outlet"),
    ingredientId: text(r.ingredient_id),
    name: text(pick(r, "name", "ingredient"), "Unnamed"),
    unit: text(r.unit),
    opening: num(r.opening),
    purchased: num(r.purchased),
    transferIn: num(r.transfer_in),
    transferOut: num(r.transfer_out),
    used: num(r.used),
    wasted: num(r.wasted),
    adjusted: num(r.adjusted),
    counted: num(r.counted),
    closing: num(r.closing),
  }));
  const rows = list(o.details).map((r): MovementLine => ({
    businessDate: text(r.business_date),
    at: textOrNull(r.at),
    outletName: text(r.outlet_name),
    ingredient: text(pick(r, "name", "ingredient"), "Unnamed"),
    unit: text(r.unit),
    kind: text(r.kind),
    qty: num(r.qty),
    unitCost: numOrNull(r.unit_cost),
    value: numOrNull(r.value),
    reason: text(r.reason),
    note: text(r.note),
    billNumber: textOrNull(r.bill_number),
    userName: text(pick(r, "user_name", "user")),
  }));
  return {
    summary,
    rows,
    cap: capOf(o, rows.length),
    totals: {
      lines: int(t.rows) || summary.length,
      movements: int(t.movements) || int(o.total_rows) || rows.length,
      purchasedValue: num(t.purchased_value),
      usedValue: num(t.used_value),
      wastedValue: num(t.wasted_value),
      adjustedValue: num(t.adjusted_value),
      countedValue: num(t.counted_value),
    },
  };
}

// ---------- food cost (report_food_cost) ----------

export type FoodCostDay = { businessDate: string; netSalesCovered: number; cost: number; costPct: number | null };
export type FoodCostDish = {
  productId: string;
  name: string;
  qtySold: number;
  netSales: number;
  /** Null when the dish has no recipe. */
  cost: number | null;
  costPct: number | null;
  margin: number | null;
  hasRecipe: boolean;
};
export type FoodCostReport = {
  byDay: FoodCostDay[];
  byDish: FoodCostDish[];
  totals: { netSalesAll: number; netSalesCovered: number; coveragePct: number | null; cost: number; costPct: number | null };
  wastageCost: number;
};

export function parseFoodCost(json: unknown): FoodCostReport {
  const o = obj(json);
  const t = obj(o.totals);
  return {
    byDay: list(o.by_day).map((r) => ({
      businessDate: text(r.business_date),
      netSalesCovered: num(r.net_sales_covered),
      cost: num(r.cost),
      costPct: numOrNull(r.cost_pct),
    })),
    byDish: list(o.by_dish).map((r): FoodCostDish => {
      const cost = numOrNull(r.cost);
      return {
        productId: text(r.product_id),
        name: text(r.name, "Unnamed"),
        qtySold: num(r.qty_sold),
        netSales: num(r.net_sales),
        cost,
        costPct: numOrNull(r.cost_pct),
        margin: numOrNull(r.margin),
        // a dish without a recipe is the one with no cost, whatever the flag says
        hasRecipe: r.has_recipe === true && cost !== null,
      };
    }),
    totals: {
      netSalesAll: num(t.net_sales_all),
      netSalesCovered: num(t.net_sales_covered),
      coveragePct: numOrNull(t.coverage_pct),
      cost: num(t.cost),
      costPct: numOrNull(t.cost_pct),
    },
    wastageCost: num(pick(o, "wastage_cost") ?? t.wastage_cost),
  };
}

/** Dishes that sold but have no recipe, so are left out of the percentage. */
export function dishesWithoutRecipe(rows: FoodCostDish[]): FoodCostDish[] {
  return rows.filter((d) => !d.hasRecipe);
}

/** "62% of sales are from dishes with a recipe." with a warning tail when coverage is under 100. */
export function coverageNote(t: FoodCostReport["totals"], missingDishes: number): string {
  if (t.coveragePct === null) return "";
  if (t.coveragePct >= 99.95 && missingDishes === 0) return "Every dish sold has a recipe, so the percentage covers all sales.";
  const dishes = missingDishes === 1 ? "1 dish" : `${missingDishes} dishes`;
  return `${pctText(t.coveragePct)} of sales come from dishes with a recipe. ${dishes} sold without a recipe, so their cost is not counted and the percentage covers the rest only.`;
}

// ---------- wastage (report_wastage) ----------

export type WastageGroup = { label: string; lines: number; qty: number | null; value: number };
export type WastageRow = {
  businessDate: string;
  at: string | null;
  outletName: string;
  ingredient: string;
  unit: string;
  qty: number;
  unitCost: number | null;
  value: number | null;
  reason: string;
  note: string;
  userName: string;
};
export type WastageReport = {
  byReason: WastageGroup[];
  byIngredient: (WastageGroup & { unit: string })[];
  byDay: WastageGroup[];
  byUser: WastageGroup[];
  rows: WastageRow[];
  cap: Cap;
  totals: { lines: number; value: number };
};

export function parseWastage(json: unknown): WastageReport {
  const o = obj(json);
  const t = obj(o.totals);
  const g = (r: Record<string, unknown>, label: string): WastageGroup => ({
    label,
    lines: int(pick(r, "lines", "count")),
    qty: numOrNull(r.qty),
    value: num(r.value),
  });
  const rows = list(o.rows).map((r): WastageRow => ({
    businessDate: text(r.business_date),
    at: textOrNull(r.at),
    outletName: text(r.outlet_name),
    ingredient: text(pick(r, "ingredient", "name"), "Unnamed"),
    unit: text(r.unit),
    qty: Math.abs(num(r.qty)),
    unitCost: numOrNull(r.unit_cost),
    value: numOrNull(r.value),
    reason: text(r.reason, "No reason"),
    note: text(r.note),
    userName: text(pick(r, "user", "user_name", "staff_name")),
  }));
  return {
    byReason: list(o.by_reason).map((r) => g(r, text(r.reason, "No reason"))),
    byIngredient: list(o.by_ingredient).map((r) => ({ ...g(r, text(pick(r, "name", "ingredient"), "Unnamed")), unit: text(r.unit) })),
    byDay: list(o.by_day).map((r) => g(r, text(r.business_date))),
    byUser: list(o.by_user).map((r) => g(r, text(pick(r, "staff_name", "user_name"), "Unknown"))),
    rows,
    cap: capOf(o, rows.length),
    totals: { lines: int(pick(t, "lines", "qty_lines")) || rows.length, value: num(t.value) },
  };
}

// ---------- customers (report_customers) ----------

export type CustomerRow = {
  customerId: string;
  name: string;
  phone: string;
  visits: number;
  /** Null when the person may not see money. */
  spend: number | null;
  avgBill: number | null;
  firstVisitOn: string | null;
  lastVisitOn: string | null;
  isNew: boolean;
};
export type CustomerDay = { businessDate: string; billsWithCustomer: number; newCustomers: number; repeatCustomers: number; spend: number | null };
export type CustomerReport = {
  money: boolean;
  byCustomer: CustomerRow[];
  byDay: CustomerDay[];
  totals: {
    customers: number;
    new: number;
    repeat: number;
    repeatRate: number | null;
    spend: number | null;
    billsWithCustomer: number;
    billsTotal: number;
    captureRate: number | null;
  };
};

export function parseCustomers(json: unknown): CustomerReport {
  const o = obj(json);
  const t = obj(o.totals);
  return {
    money: o.money === true,
    byCustomer: list(o.by_customer).map((r): CustomerRow => ({
      customerId: text(r.customer_id),
      name: text(r.name, "Unnamed"),
      phone: text(r.phone),
      visits: int(r.visits),
      spend: numOrNull(r.spend),
      avgBill: numOrNull(r.avg_bill),
      firstVisitOn: textOrNull(r.first_visit_on),
      lastVisitOn: textOrNull(r.last_visit_on),
      isNew: r.is_new === true,
    })),
    byDay: list(o.by_day).map((r): CustomerDay => ({
      businessDate: text(r.business_date),
      billsWithCustomer: int(r.bills_with_customer),
      newCustomers: int(r.new_customers),
      repeatCustomers: int(r.repeat_customers),
      spend: numOrNull(r.spend),
    })),
    totals: {
      customers: int(t.customers),
      new: int(t.new),
      repeat: int(t.repeat),
      repeatRate: numOrNull(t.repeat_rate),
      spend: numOrNull(t.spend),
      billsWithCustomer: int(t.bills_with_customer),
      billsTotal: int(t.bills_total),
      captureRate: numOrNull(t.capture_rate),
    },
  };
}

/** repeat_rate and capture_rate come from the database already as percents with 1 decimal (report_customers, migration 146): 42 means 42%. */
export function ratePct(v: number | null): number | null {
  return v;
}

/** "3 of 8 bills had a customer attached." */
export function captureNote(t: Pick<CustomerReport["totals"], "billsWithCustomer" | "billsTotal">): string {
  if (t.billsTotal <= 0) return "";
  return `${t.billsWithCustomer} of ${t.billsTotal} bill${t.billsTotal === 1 ? "" : "s"} had a customer attached; only those are in this report.`;
}

// ---------- loyalty ledger (report_loyalty_ledger) ----------

export type LedgerKind = "earned" | "redeemed" | "reversed" | "adjusted" | "other";
export type LedgerRow = {
  at: string | null;
  customer: string;
  kind: LedgerKind;
  kindText: string;
  points: number;
  billNumber: string | null;
  /** "Manual" for lines with no bill (restaurant-wide). */
  outlet: string;
  userName: string;
};
export type LedgerDay = { businessDate: string; earned: number; redeemed: number; reversed: number; adjusted: number };
export type LoyaltyLedgerReport = {
  byDay: LedgerDay[];
  rows: LedgerRow[];
  cap: Cap;
  totals: { earned: number; redeemed: number; reversed: number; adjusted: number; net: number };
  liability: { pointsOutstanding: number; rupeeValue: number | null; customersWithPoints: number };
};

export function ledgerKind(v: unknown): LedgerKind {
  switch (String(v ?? "").toLowerCase()) {
    case "earn":
    case "earned":
      return "earned";
    case "redeem":
    case "redeemed":
      return "redeemed";
    case "expire":
    case "expired":
      return "adjusted";
    case "reverse":
    case "reversed":
    case "reversal":
      return "reversed";
    case "adjust":
    case "adjusted":
    case "adjustment":
      return "adjusted";
    default:
      return "other";
  }
}

const LEDGER_TEXT: Record<LedgerKind, string> = {
  earned: "Earned",
  redeemed: "Redeemed",
  reversed: "Reversed",
  adjusted: "Adjusted",
  other: "Other",
};

export function parseLoyaltyLedger(json: unknown): LoyaltyLedgerReport {
  const o = obj(json);
  const t = obj(o.totals);
  const l = obj(o.liability);
  const rows = list(o.rows).map((r): LedgerRow => {
    const kind = ledgerKind(r.kind);
    return {
      at: textOrNull(r.at),
      customer: text(r.customer, "Unnamed"),
      kind,
      kindText: kind === "other" ? text(r.kind, "Other") : LEDGER_TEXT[kind],
      points: num(r.points),
      billNumber: textOrNull(r.bill_number),
      outlet: text(r.outlet, "Manual"),
      userName: text(pick(r, "user", "user_name")),
    };
  });
  return {
    byDay: list(o.by_day).map((r) => ({
      businessDate: text(r.business_date),
      earned: num(r.earned),
      redeemed: num(r.redeemed),
      reversed: num(r.reversed),
      adjusted: num(r.adjusted),
    })),
    rows,
    cap: capOf(o, rows.length),
    totals: { earned: num(t.earned), redeemed: num(t.redeemed), reversed: num(t.reversed), adjusted: num(t.adjusted), net: num(t.net) },
    liability: { pointsOutstanding: num(l.points_outstanding), rupeeValue: numOrNull(l.rupee_value), customersWithPoints: int(l.customers_with_points) },
  };
}

// ---------- Leakage summary and Table turnaround (migration 151) ----------

export type LeakageLine = { key: string; label: string; count: number; value: number | null };
export type LeakageStaff = {
  userId: string;
  staffName: string;
  voids: number;
  cancelledItems: number;
  cancelledKots: number;
  creditNotes: number;
  complimentary: number;
  reprints: number;
  moves: number;
  total: number;
};
export type LeakageReport = { money: boolean; summary: LeakageLine[]; byStaff: LeakageStaff[] };

/** Report_leakage JSON to a safe shape. Rupee values the database hides stay null. */
export function parseLeakage(json: unknown): LeakageReport {
  const o = obj(json);
  return {
    money: o.money === true,
    summary: list(o.summary).map((r) => ({ key: text(r.key), label: text(r.label, "Other"), count: int(r.count), value: numOrNull(r.value) })),
    byStaff: list(o.by_staff).map((r) => {
      const s = {
        userId: text(r.user_id),
        staffName: text(r.staff_name, "Unknown"),
        voids: int(r.voids),
        cancelledItems: int(r.cancelled_items),
        cancelledKots: int(r.cancelled_kots),
        creditNotes: int(r.credit_notes),
        complimentary: int(r.complimentary),
        reprints: int(r.reprints),
        moves: int(r.moves),
      };
      return { ...s, total: s.voids + s.cancelledItems + s.cancelledKots + s.creditNotes + s.complimentary + s.reprints + s.moves };
    }),
  };
}

export type TurnaroundReport = {
  byDay: { businessDate: string; bills: number; avgMinutes: number | null }[];
  byTable: { tableNumber: string; bills: number; avgMinutes: number | null; longestMinutes: number | null }[];
  totals: { bills: number; avgMinutes: number | null; medianMinutes: number | null; longestMinutes: number | null };
};

/** Report_table_turnaround JSON to a safe shape. */
export function parseTurnaround(json: unknown): TurnaroundReport {
  const o = obj(json);
  const t = obj(o.totals);
  return {
    byDay: list(o.by_day).map((r) => ({ businessDate: text(r.business_date), bills: int(r.bills), avgMinutes: numOrNull(r.avg_minutes) })),
    byTable: list(o.by_table).map((r) => ({
      tableNumber: text(r.table_number, "?"),
      bills: int(r.bills),
      avgMinutes: numOrNull(r.avg_minutes),
      longestMinutes: numOrNull(r.longest_minutes),
    })),
    totals: { bills: int(t.bills), avgMinutes: numOrNull(t.avg_minutes), medianMinutes: numOrNull(t.median_minutes), longestMinutes: numOrNull(t.longest_minutes) },
  };
}

/** Minutes for a table cell: "42 min", "1 h 05 min"; null is a dash. */
export function minutesText(m: number | null): string {
  if (m === null || !Number.isFinite(m)) return "—";
  const r = Math.round(m);
  if (r < 60) return `${r} min`;
  return `${Math.floor(r / 60)} h ${String(r % 60).padStart(2, "0")} min`;
}
