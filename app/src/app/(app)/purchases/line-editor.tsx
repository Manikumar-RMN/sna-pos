"use client";

import Link from "next/link";
import { money } from "@/lib/format";
import { BLANK_LINE, lineCents, linesCents, type Ingredient, type IngredientNames, type LineDraft } from "./helpers";
import { lineStyle, rowBtn } from "./ui";

/**
 * The list of ingredient lines on an order or a delivery: pick the ingredient,
 * type the quantity, check the cost per unit. The cost is filled in from the
 * ingredient's current cost and can be changed.
 */
export function LineEditor({
  lines,
  onChange,
  ingredients,
  names,
  currency,
  qtyLabel = "Quantity",
  totalLabel = "Total",
  showTax,
  agreed,
  disabled,
}: {
  lines: LineDraft[];
  onChange: (lines: LineDraft[]) => void;
  /** Ingredients that can be picked (the active ones). */
  ingredients: Ingredient[];
  /** Names of every ingredient, so a line for one that was switched off still shows what it is. */
  names: IngredientNames;
  currency: string;
  qtyLabel?: string;
  totalLabel?: string;
  /** Show a Tax % box on each line (deliveries only). */
  showTax?: boolean;
  /** Agreed price per ingredient for the chosen supplier; new lines start from it. */
  agreed?: Record<string, number>;
  disabled?: boolean;
}) {
  const active = new Set(ingredients.map((i) => i.id));
  const set = (i: number, patch: Partial<LineDraft>) => onChange(lines.map((l, j) => (j === i ? { ...l, ...patch } : l)));

  function pick(i: number, id: string) {
    const ing = ingredients.find((x) => x.id === id);
    set(i, { ingredient_id: id, buy: false, cost: agreed?.[id] != null ? String(agreed[id]) : ing ? String(ing.cost) : "" });
  }

  return (
    <div>
      {ingredients.length === 0 && (
        <p className="mb-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
          There are no ingredients yet.{" "}
          <Link href="/stock" className="font-bold underline">
            Add them on the Stock screen
          </Link>{" "}
          first.
        </p>
      )}
      <div className={`hidden gap-2 px-1 pb-1 text-xs font-semibold sm:grid ${showTax ? "sm:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)_minmax(0,1fr)_minmax(0,0.6fr)_minmax(0,0.9fr)_40px]" : "sm:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)_minmax(0,1fr)_minmax(0,0.9fr)_40px]"}`} style={{ color: "var(--color-ink-3)" }} aria-hidden="true">
        <span>Ingredient</span>
        <span>{qtyLabel}</span>
        <span>Cost per unit</span>
        {showTax && <span>Tax %</span>}
        <span className="text-right">Amount</span>
        <span />
      </div>
      <ul className="space-y-3 sm:space-y-2">
        {lines.map((l, i) => {
          const unit = l.ingredient_id ? (names[l.ingredient_id]?.unit ?? "") : "";
          const ingRow = ingredients.find((x) => x.id === l.ingredient_id);
          const canBuy = !!ingRow?.buyUnit && !!ingRow.buyFactor;
          const shown = l.buy && canBuy ? ingRow!.buyUnit! : unit;
          const gone = !!l.ingredient_id && !active.has(l.ingredient_id);
          const n = i + 1;
          return (
            <li
              key={i}
              className={`grid gap-2 rounded-2xl border p-3 ${showTax ? "sm:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)_minmax(0,1fr)_minmax(0,0.6fr)_minmax(0,0.9fr)_40px]" : "sm:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)_minmax(0,1fr)_minmax(0,0.9fr)_40px]"} sm:items-center sm:rounded-none sm:border-0 sm:p-0`}
              style={lineStyle}
            >
              <label className="block">
                <span className="mb-1 block text-xs font-semibold sm:sr-only" style={{ color: "var(--color-ink-2)" }}>
                  Ingredient (line {n})
                </span>
                <select className="field h-10 text-sm" value={l.ingredient_id} onChange={(e) => pick(i, e.target.value)} disabled={disabled}>
                  <option value="">Choose an ingredient…</option>
                  {gone && <option value={l.ingredient_id}>{names[l.ingredient_id]?.name ?? "Ingredient"} (no longer used)</option>}
                  {ingredients.map((x) => (
                    <option key={x.id} value={x.id} disabled={x.id !== l.ingredient_id && lines.some((o) => o.ingredient_id === x.id)}>
                      {x.name} ({x.unit})
                    </option>
                  ))}
                </select>
              </label>
              <label className="block">
                <span className="mb-1 block text-xs font-semibold sm:sr-only" style={{ color: "var(--color-ink-2)" }}>
                  {qtyLabel} (line {n})
                </span>
                <span className="flex items-center gap-2">
                  <input className="field h-10 min-w-0 flex-1 text-sm" inputMode="decimal" placeholder="0" value={l.qty} onChange={(e) => set(i, { qty: e.target.value })} disabled={disabled} />
                  <span className="w-9 shrink-0 text-sm font-semibold" style={{ color: "var(--color-ink-3)" }}>
                    {shown}
                  </span>
                </span>
                {canBuy && (
                  <select
                    className="field mt-1 h-8 text-xs"
                    value={l.buy ? "buy" : "stock"}
                    onChange={(e) => set(i, { buy: e.target.value === "buy", qty: "", cost: "" })}
                    disabled={disabled}
                    aria-label={`Unit (line ${n})`}
                  >
                    <option value="stock">in {unit}</option>
                    <option value="buy">in {ingRow!.buyUnit} (1 = {ingRow!.buyFactor} {unit})</option>
                  </select>
                )}
              </label>
              <label className="block">
                <span className="mb-1 block text-xs font-semibold sm:sr-only" style={{ color: "var(--color-ink-2)" }}>
                  Cost per {shown || "unit"} (line {n})
                </span>
                <input className="field h-10 text-sm" inputMode="decimal" placeholder="0.00" value={l.cost} onChange={(e) => set(i, { cost: e.target.value })} disabled={disabled} />
                {agreed?.[l.ingredient_id] != null && !l.buy && (
                  <span className="mt-1 block text-xs" style={{ color: Number(l.cost) === agreed[l.ingredient_id] ? "var(--color-ink-3)" : "var(--color-warn)" }}>
                    Agreed rate {money(agreed[l.ingredient_id], currency)}
                  </span>
                )}
              </label>
              {showTax && (
              <label className="block">
                <span className="mb-1 block text-xs font-semibold sm:sr-only" style={{ color: "var(--color-ink-2)" }}>
                  Tax % (line {n})
                </span>
                <input className="field h-10 text-sm" inputMode="decimal" placeholder="Tax %" value={l.taxRate ?? ""} onChange={(e) => set(i, { taxRate: e.target.value })} disabled={disabled} />
              </label>
              )}
              <div className="flex items-center justify-between text-sm sm:block sm:text-right">
                <span className="text-xs font-semibold sm:hidden" style={{ color: "var(--color-ink-2)" }}>
                  Amount
                </span>
                <span className="font-semibold tabular-nums">{l.ingredient_id ? money(lineCents(l.qty, l.cost) / 100, currency) : "—"}</span>
              </div>
              <button
                type="button"
                className="inline-flex min-h-10 min-w-10 items-center justify-center rounded-xl border px-3 text-sm font-bold sm:px-0"
                style={{ ...lineStyle, color: "var(--color-bad)" }}
                onClick={() => onChange(lines.length > 1 ? lines.filter((_, j) => j !== i) : [{ ...BLANK_LINE }])}
                disabled={disabled}
                aria-label={`Remove line ${n}`}
              >
                <span aria-hidden="true" className="sm:hidden">
                  Remove
                </span>
                <span aria-hidden="true" className="hidden sm:inline">
                  ×
                </span>
              </button>
              {showTax && (
                <div className="col-span-full flex flex-wrap items-center gap-2 sm:pl-1">
                  <label className="flex items-center gap-2 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                    Batch no.
                    <input className="field h-9 w-32 text-sm" placeholder="optional" maxLength={40} value={l.batch ?? ""} onChange={(e) => set(i, { batch: e.target.value })} disabled={disabled} aria-label={`Batch number (line ${n})`} />
                  </label>
                  <label className="flex items-center gap-2 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                    Best before
                    <input className="field h-9 text-sm" type="date" value={l.expiry ?? ""} onChange={(e) => set(i, { expiry: e.target.value })} disabled={disabled} aria-label={`Expiry date (line ${n})`} />
                  </label>
                </div>
              )}
            </li>
          );
        })}
      </ul>
      <div className="mt-3 flex flex-wrap items-center justify-between gap-2">
        <button type="button" className={rowBtn} style={lineStyle} onClick={() => onChange([...lines, { ...BLANK_LINE }])} disabled={disabled || lines.length >= 200}>
          + Add line
        </button>
        <div className="text-sm">
          <span style={{ color: "var(--color-ink-3)" }}>{totalLabel}: </span>
          <b className="tabular-nums">{money(linesCents(lines) / 100, currency)}</b>
        </div>
      </div>
    </div>
  );
}
