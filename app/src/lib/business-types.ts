/** The kinds of business SNA POS serves. The type sets starting defaults only; every setting can still be changed. */
export const BUSINESS_TYPES = [
  { key: "restaurant", label: "Restaurant", hint: "Tables, KOT, dine-in, takeaway and delivery" },
  { key: "fine_dine", label: "Fine dine", hint: "Tables, courses, dine-in first" },
  { key: "cafe", label: "Café", hint: "Counter billing, tokens for takeaway, sizes and combos" },
  { key: "qsr", label: "QSR (quick service)", hint: "Counter billing, token on every bill, combos, order-ready screen" },
  { key: "pizzeria", label: "Pizzeria", hint: "Sizes, combos, takeaway and delivery" },
  { key: "desserts", label: "Desserts / ice cream", hint: "Counter billing, tokens, sizes" },
  { key: "bakery", label: "Bakery", hint: "Counter billing, takeaway and delivery" },
  { key: "bar", label: "Bar & brewery", hint: "Tables and tabs, happy hours" },
  { key: "food_court", label: "Food court", hint: "Counter billing only, token on every bill" },
  { key: "canteen", label: "Canteen", hint: "Counter billing only, token on every bill" },
  { key: "cloud_kitchen", label: "Cloud kitchen", hint: "Delivery and takeaway only, no tables" },
  { key: "chain", label: "Large chain", hint: "Several outlets, all kinds of bill" },
] as const;

export type BusinessType = (typeof BUSINESS_TYPES)[number]["key"];

export const businessTypeLabel = (k: string | null | undefined) => BUSINESS_TYPES.find((t) => t.key === k)?.label ?? "Restaurant";
