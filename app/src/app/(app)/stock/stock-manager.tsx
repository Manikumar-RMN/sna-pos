"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { fmtQty, foodCostTone, isAttention, parseQty, recipeCost, STATUS_LABEL, STATUS_RANK, stockStatus, STOCK_UNITS, UNIT_HINT, unitMismatchWarning, type BuyUnits, type StockStatus } from "@/lib/stock";
import { saveIngredient, saveRecipe, type StockResult } from "./actions";
import { StockIn } from "./stock-in";
import { WastageForm, type RecentAdjust } from "./wastage-form";

export type Level = { id: string; name: string; unit: string; cost: number; reorder: number; stock: number; used: number; wasted: number; bought: number; count_diff: number; category: string | null; item_type?: string; hsn?: string };
export type FoodCost = { product: string; price: number; cost: number; cost_pct: number | null };
type Product = { id: string; name: string; price: number };
type RecipeRow = { product_id: string; ingredient_id: string; qty: number };

const UNITS = STOCK_UNITS;
const n2 = fmtQty;
const STATUS_STYLE: Record<StockStatus, { bg: string; fg: string }> = {
  ok: { bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  low: { bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  out: { bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
  negative: { bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
};
type Tab = "levels" | "in" | "wastage" | "recipes" | "cost";

export function StockManager({
  currency,
  timezone,
  levels,
  foodCost,
  products,
  recipes,
  recent,
  canManage,
  canAdjust,
  initialFilter,
  buyUnits = {},
  categoryList = [],
}: {
  buyUnits?: BuyUnits;
  /** The owner's item-group list. Empty means free text (the groups already in use are suggested). */
  categoryList?: string[];
  currency: string;
  timezone: string;
  levels: Level[];
  foodCost: FoodCost[];
  products: Product[];
  recipes: RecipeRow[];
  recent: RecentAdjust[];
  canManage: boolean;
  canAdjust: boolean;
  initialFilter?: "low";
}) {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("levels");
  const [lowOnly, setLowOnly] = useState(initialFilter === "low");
  const [search, setSearch] = useState("");
  const [typeFilter, setTypeFilter] = useState<"all" | "food" | "general">("all");
  // Ingredient chosen with the row buttons, carried to the Stock in / Wastage tab.
  const [preset, setPreset] = useState<string>("");
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const m = (x: number) => money(Number(x), currency);

  function run(fn: () => Promise<StockResult>, after?: () => void) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
      if (r.ok) {
        after?.();
        router.refresh();
      }
    });
  }

  // New / edit ingredient.
  const [edit, setEdit] = useState<{ id: string | null; name: string; unit: string; cost: string; reorder: string; category: string; buyUnit: string; buyFactor: string; itemType: "food" | "general"; hsn: string } | null>(null);
  // Recipe editor.
  const [recipeFor, setRecipeFor] = useState<string>("");
  const [recipeRows, setRecipeRows] = useState<{ ingredient_id: string; qty: string }[]>([]);

  const withStatus = levels.map((l) => ({ l, status: stockStatus(Number(l.stock), Number(l.reorder)) }));
  const low = withStatus.filter((x) => isAttention(x.status)).map((x) => x.l);
  const needle = search.trim().toLowerCase();
  const shown = withStatus
    .filter((x) => (!lowOnly || isAttention(x.status)) && (typeFilter === "all" || (x.l.item_type === "general" ? "general" : "food") === typeFilter) && (!needle || x.l.name.toLowerCase().includes(needle) || (x.l.category ?? "").toLowerCase().includes(needle)))
    .sort((a, b) => (lowOnly ? STATUS_RANK[a.status] - STATUS_RANK[b.status] || a.l.name.localeCompare(b.l.name) : 0));
  // Groups already in use, offered as suggestions when typing a group.
  const groups = categoryList.length > 0 ? categoryList : Array.from(new Set(levels.map((l) => (l.category ?? "").trim()).filter(Boolean))).sort((a, b) => a.localeCompare(b));

  const ingCosts = levels.map((l) => ({ id: l.id, cost: Number(l.cost) }));
  function dishCost(p: Product): string {
    const { pct } = recipeCost(recipes.filter((r) => r.product_id === p.id).map((r) => ({ ingredient_id: r.ingredient_id, qty: String(r.qty) })), ingCosts, p.price);
    return pct == null ? "" : `(${pct}%)`;
  }
  const recipeDish = products.find((p) => p.id === recipeFor);
  const liveCost = recipeDish ? recipeCost(recipeRows, ingCosts, recipeDish.price) : null;
  const liveTone = liveCost ? foodCostTone(liveCost.pct) : "none";

  function openRecipe(pid: string) {
    setRecipeFor(pid);
    setRecipeRows(recipes.filter((r) => r.product_id === pid).map((r) => ({ ingredient_id: r.ingredient_id, qty: String(r.qty) })));
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-1.5">
        {(
          [
            ["levels", "Stock", true],
            ["in", "Stock in", canManage],
            ["wastage", "Wastage / adjust", canAdjust],
            ["recipes", "Recipes", canManage],
            ["cost", "Food cost", true],
          ] as const
        )
          .filter(([, , show]) => show)
          .map(([k, label]) => (
          <button
            key={k}
            onClick={() => setTab(k)}
            className="rounded-full border px-4 py-2 text-sm font-semibold"
            style={{ borderColor: tab === k ? "var(--color-brand)" : "var(--color-line)", background: tab === k ? "var(--color-brand)" : "transparent", color: tab === k ? "#fff" : "var(--color-ink-2)" }}
          >
            {label}
          </button>
        ))}
      </div>

      {msg && (
        <p className="rounded-lg px-3 py-2 text-sm" role={msg.ok ? "status" : "alert"} style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {msg.text}
        </p>
      )}

      {tab === "levels" && (
        <>
          {low.length > 0 && (
            <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl px-4 py-3 text-sm" style={{ background: "var(--color-warn-soft)" }}>
              <div className="min-w-0">
                <b style={{ color: "var(--color-warn)" }}>Needs attention:</b> {low.map((l) => `${l.name} (${n2(l.stock)} ${l.unit})`).join(", ")}
              </div>
              {canManage && (
                <Link href="/purchases?tab=orders&low=1" className="btn btn-primary h-10 min-h-0 shrink-0 px-4 text-sm">
                  Order low stock
                </Link>
              )}
            </div>
          )}
          <div className="flex flex-wrap items-center gap-2">
            <input className="field h-10 min-w-0 flex-1 text-sm" style={{ minWidth: 160 }} placeholder="Search item or group" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search" />
            <select className="field h-10 text-sm" value={typeFilter} onChange={(e) => setTypeFilter(e.target.value as "all" | "food" | "general")} aria-label="Show item type">
              <option value="all">All items</option>
              <option value="food">Food</option>
              <option value="general">General</option>
            </select>
            <label className="flex items-center gap-2 text-sm font-semibold">
              <input type="checkbox" checked={lowOnly} onChange={(e) => setLowOnly(e.target.checked)} /> Low only
            </label>
            <Link href="/stock/requests" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }}>
              Requests
            </Link>
            <Link href="/stock/production" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }}>
              Production
            </Link>
            <Link href="/stock/expiry" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }}>
              Expiry
            </Link>
            <Link href="/stock/closing" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }}>
              Opening and month closing
            </Link>
            {canAdjust && (
              <Link href="/stock/count" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }}>
                Count stock
              </Link>
            )}
          </div>
          <div className="card overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr style={{ color: "var(--color-ink-3)" }}>
                  <th className="px-3 py-2 text-left text-xs font-semibold">Ingredient</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">In stock</th>
                  <th className="px-3 py-2 text-left text-xs font-semibold">Status</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Used (7 days)</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Wasted</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Cost / unit</th>
                  {(canManage || canAdjust) && <th className="px-3 py-2" />}
                </tr>
              </thead>
              <tbody>
                {shown.length === 0 && (
                  <tr>
                    <td colSpan={7} className="px-3 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                      {levels.length === 0 ? (canManage ? "No items yet. Add one below." : "No items yet.") : lowOnly ? "Nothing is low. Good." : "Nothing matches the search."}
                    </td>
                  </tr>
                )}
                {shown.map(({ l, status }) => {
                  const st = STATUS_STYLE[status];
                  return (
                    <tr key={l.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                      <td className="px-3 py-2">
                        {canManage ? (
                          <button className="text-left font-semibold" onClick={() => setEdit({ id: l.id, name: l.name, unit: l.unit, cost: String(l.cost), reorder: String(l.reorder), category: l.category ?? "", buyUnit: buyUnits[l.id]?.unit ?? "", buyFactor: buyUnits[l.id] ? String(buyUnits[l.id].factor) : "", itemType: l.item_type === "general" ? "general" : "food", hsn: l.hsn ?? "" })}>
                            {l.name}
                          </button>
                        ) : (
                          <span className="font-semibold">{l.name}</span>
                        )}
                        {l.item_type === "general" && (
                          <span className="ml-2 inline-block rounded-full px-2 py-0.5 text-[11px] font-semibold" style={{ background: "var(--color-brand-soft, var(--color-ground))", color: "var(--color-brand)" }}>
                            General
                          </span>
                        )}
                        {l.category && (
                          <span className="ml-2 inline-block rounded-full px-2 py-0.5 text-[11px] font-semibold" style={{ background: "var(--color-ground)", color: "var(--color-ink-3)" }}>
                            {l.category}
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums" style={{ color: status === "ok" ? undefined : st.fg, fontWeight: status === "ok" ? 400 : 700 }}>
                        {n2(l.stock)} {l.unit}
                      </td>
                      <td className="px-3 py-2">
                        <span className="inline-block rounded-full px-2 py-0.5 text-[11px] font-semibold" style={{ background: st.bg, color: st.fg }}>
                          {STATUS_LABEL[status]}
                        </span>
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">{n2(l.used)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{n2(l.wasted)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{m(l.cost)}</td>
                      {(canManage || canAdjust) && (
                        <td className="px-3 py-2 text-right">
                          <div className="flex justify-end gap-1">
                            {canManage && (
                              <button
                                className="rounded-md border px-2 py-1 text-[11px] font-semibold"
                                style={{ borderColor: "var(--color-line)" }}
                                onClick={() => {
                                  setPreset(l.id);
                                  setTab("in");
                                }}
                              >
                                + Bought
                              </button>
                            )}
                            {canAdjust && (
                              <button
                                className="rounded-md border px-2 py-1 text-[11px] font-semibold"
                                style={{ borderColor: "var(--color-line)" }}
                                onClick={() => {
                                  setPreset(l.id);
                                  setTab("wastage");
                                }}
                              >
                                Wasted
                              </button>
                            )}
                          </div>
                        </td>
                      )}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <p className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Stock can go below zero when food is billed before it is recorded: the bill is never blocked, the number turns red. {UNIT_HINT}
          </p>

          {!canManage ? null : edit ? (
            <section className="card p-4">
              <h2 className="text-sm font-bold">{edit.id ? "Edit item" : "New item"}</h2>
              <div className="mt-3 grid gap-2 sm:grid-cols-4">
                <input className="field h-10 text-sm sm:col-span-2" placeholder="Name, e.g. Dosa batter or Notebook" value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} maxLength={60} />
                <select className="field h-10 text-sm" value={edit.unit} onChange={(e) => setEdit({ ...edit, unit: e.target.value })} aria-label="Unit">
                  {UNITS.map((u) => (
                    <option key={u}>{u}</option>
                  ))}
                </select>
                <input className="field h-10 text-sm" inputMode="decimal" placeholder="Cost per unit" value={edit.cost} onChange={(e) => setEdit({ ...edit, cost: e.target.value })} />
                <select className="field h-10 text-sm sm:col-span-2" value={edit.itemType} onChange={(e) => setEdit({ ...edit, itemType: e.target.value as "food" | "general" })} aria-label="Item type">
                  <option value="food">Food — used in dishes or prepared items</option>
                  <option value="general">General — pens, notebooks, cleaning supplies</option>
                </select>
                <input className="field h-10 text-sm sm:col-span-2" inputMode="decimal" placeholder="Warn when stock falls to (optional)" value={edit.reorder} onChange={(e) => setEdit({ ...edit, reorder: e.target.value })} />
                <input
                  className="field h-10 text-sm sm:col-span-2"
                  placeholder={categoryList.length > 0 ? "Group (choose from the list)" : "Group, e.g. Vegetables (optional)"}
                  aria-label="Group (optional)"
                  list="ingredient-groups"
                  value={edit.category}
                  onChange={(e) => setEdit({ ...edit, category: e.target.value })}
                  maxLength={40}
                />
                <input
                  className="field h-10 text-sm sm:col-span-2"
                  inputMode="numeric"
                  placeholder="HSN code for purchase tax (optional), 4 to 8 digits"
                  aria-label="HSN code (optional)"
                  value={edit.hsn}
                  onChange={(e) => setEdit({ ...edit, hsn: e.target.value.replace(/[^0-9]/g, "").slice(0, 8) })}
                  maxLength={8}
                />
                <input
                  className="field h-10 text-sm sm:col-span-2"
                  placeholder="Bought in (optional), e.g. kg, box, can"
                  aria-label="Bought in (optional)"
                  value={edit.buyUnit}
                  onChange={(e) => setEdit({ ...edit, buyUnit: e.target.value })}
                  maxLength={20}
                />
                {edit.buyUnit.trim() !== "" && (
                  <input
                    className="field h-10 text-sm sm:col-span-2"
                    inputMode="decimal"
                    placeholder={`1 ${edit.buyUnit.trim()} = how many ${edit.unit}?`}
                    aria-label={`1 ${edit.buyUnit.trim()} equals how many ${edit.unit}`}
                    value={edit.buyFactor}
                    onChange={(e) => setEdit({ ...edit, buyFactor: e.target.value })}
                  />
                )}
                <datalist id="ingredient-groups">
                  {groups.map((g) => (
                    <option key={g} value={g} />
                  ))}
                </datalist>
              </div>
              <div className="mt-3 flex gap-2">
                <button className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setEdit(null)}>
                  Cancel
                </button>
                <button
                  className="btn btn-primary px-4 text-sm"
                  disabled={pending || !edit.name.trim()}
                  onClick={() => run(() => saveIngredient({ id: edit.id, name: edit.name, unit: edit.unit, cost: Number(edit.cost) || 0, reorder: Number(edit.reorder) || 0, category: edit.category, purchaseUnit: edit.buyUnit, purchaseFactor: Number(edit.buyFactor) || 1, itemType: edit.itemType, hsn: edit.hsn }), () => setEdit(null))}
                >
                  {pending ? "Saving…" : "Save item"}
                </button>
              </div>
            </section>
          ) : (
            <button className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setEdit({ id: null, name: "", unit: "kg", cost: "", reorder: "", category: "", buyUnit: "", buyFactor: "", itemType: "food", hsn: "" })}>
              + Add item
            </button>
          )}
        </>
      )}

      {tab === "in" && canManage && <StockIn currency={currency} buyUnits={buyUnits} ingredients={levels.map((l) => ({ id: l.id, name: l.name, unit: l.unit, cost: Number(l.cost), reorder: Number(l.reorder), stock: Number(l.stock), category: l.category }))} presetIngredient={preset || undefined} />}

      {tab === "wastage" && canAdjust && (
        <WastageForm currency={currency} timezone={timezone} ingredients={levels.map((l) => ({ id: l.id, name: l.name, unit: l.unit, cost: Number(l.cost), reorder: Number(l.reorder), stock: Number(l.stock), category: l.category }))} recent={recent} presetIngredient={preset || undefined} />
      )}

      {tab === "recipes" && canManage && (
        <section className="card p-4">
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            For each dish, say how much of each ingredient one portion uses. Dishes without a recipe do not change stock. {UNIT_HINT}
          </p>
          <select className="field mt-3 h-10 text-sm" value={recipeFor} onChange={(e) => openRecipe(e.target.value)} aria-label="Dish">
            <option value="">Choose a dish…</option>
            {products.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
                {recipes.some((r) => r.product_id === p.id) ? ` ✓ ${dishCost(p)}` : ""}
              </option>
            ))}
          </select>
          {recipeFor && (
            <>
              <ul className="mt-3 space-y-2">
                {recipeRows.map((row, i) => (
                  <li key={i} className="flex gap-2">
                    {/* .field sets width:100%, which beats the utility widths, so the sizes are set inline: the name gets the free space. */}
                    <select
                      className="field h-10 min-w-0 flex-1 truncate text-sm"
                      style={{ flex: "1 1 0%", minWidth: 140, textOverflow: "ellipsis" }}
                      value={row.ingredient_id}
                      onChange={(e) => setRecipeRows(recipeRows.map((r, j) => (j === i ? { ...r, ingredient_id: e.target.value } : r)))}
                      aria-label="Ingredient"
                    >
                      <option value="">Ingredient…</option>
                      {levels.filter((l) => l.item_type !== "general").map((l) => (
                        <option key={l.id} value={l.id}>
                          {l.name} ({l.unit})
                        </option>
                      ))}
                    </select>
                    <input
                      className="field h-10 w-28 shrink-0 text-sm"
                      style={{ flex: "none", width: 96 }}
                      inputMode="decimal"
                      placeholder={`Qty (${levels.find((l) => l.id === row.ingredient_id)?.unit ?? "unit"})`}
                      value={row.qty}
                      onChange={(e) => setRecipeRows(recipeRows.map((r, j) => (j === i ? { ...r, qty: e.target.value } : r)))}
                      aria-label="Quantity per portion"
                    />
                    <button className="shrink-0 px-2 text-sm font-bold" style={{ color: "var(--color-bad)", flex: "none" }} onClick={() => setRecipeRows(recipeRows.filter((_, j) => j !== i))} aria-label="Remove ingredient">
                      ×
                    </button>
                  </li>
                ))}
              </ul>
              {recipeRows.map((row, i) => {
                const unit = levels.find((l) => l.id === row.ingredient_id)?.unit ?? "";
                const w = unitMismatchWarning(unit, parseQty(row.qty));
                return w ? (
                  <p key={i} className="mt-2 text-xs font-semibold" style={{ color: "var(--color-warn)" }} role="note">
                    {levels.find((l) => l.id === row.ingredient_id)?.name}: {w}
                  </p>
                ) : null;
              })}
              {liveCost && recipeDish && (
                <p className="mt-3 text-sm">
                  Cost of one portion at today&rsquo;s prices: <b className="tabular-nums">{m(liveCost.cost)}</b> on a price of {m(recipeDish.price)}
                  {liveCost.pct != null && (
                    <>
                      {" "}
                      = food cost{" "}
                      <b className="tabular-nums" style={{ color: liveTone === "ok" ? "var(--color-ok)" : "var(--color-bad)" }}>
                        {liveCost.pct}%
                      </b>
                    </>
                  )}
                  {liveTone === "absurd" && <span className="block text-xs font-semibold" style={{ color: "var(--color-bad)" }}>The cost is more than the price. Check the units (grams or kg?).</span>}
                </p>
              )}
              <div className="mt-3 flex flex-wrap gap-2">
                <button className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setRecipeRows([...recipeRows, { ingredient_id: "", qty: "" }])}>
                  + Ingredient
                </button>
                <button
                  className="btn btn-primary px-4 text-sm"
                  disabled={pending}
                  onClick={() =>
                    run(() =>
                      saveRecipe(
                        recipeFor,
                        recipeRows.filter((r) => r.ingredient_id && Number(r.qty) > 0).map((r) => ({ ingredient_id: r.ingredient_id, qty: Number(r.qty) })),
                      ),
                    )
                  }
                >
                  {pending ? "Saving…" : "Save recipe"}
                </button>
              </div>
            </>
          )}
        </section>
      )}

      {tab === "cost" && (
        <div className="card overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr style={{ color: "var(--color-ink-3)" }}>
                <th className="px-3 py-2 text-left text-xs font-semibold">Dish</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Price</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Ingredient cost</th>
                <th className="px-3 py-2 text-right text-xs font-semibold">Food cost %</th>
              </tr>
            </thead>
            <tbody>
              {foodCost.length === 0 && (
                <tr>
                  <td colSpan={4} className="px-3 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                    Add recipes to see the food cost of each dish.
                  </td>
                </tr>
              )}
              {foodCost.map((f, i) => (
                <tr key={i} style={{ borderTop: "1px solid var(--color-line)" }}>
                  <td className="px-3 py-2">{f.product}</td>
                  <td className="px-3 py-2 text-right tabular-nums">{m(f.price)}</td>
                  <td className="px-3 py-2 text-right tabular-nums">{m(f.cost)}</td>
                  <td className="px-3 py-2 text-right font-semibold tabular-nums" style={{ color: foodCostTone(f.cost_pct == null ? null : Number(f.cost_pct)) === "ok" ? "var(--color-ok)" : "var(--color-bad)" }}>
                    {f.cost_pct == null ? "—" : `${f.cost_pct}%`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="px-3 py-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Most restaurants aim for 25–35%. Costs use today&rsquo;s average ingredient price. Over 100% usually means a unit mix-up (grams against kg).
          </p>
        </div>
      )}
    </div>
  );
}
