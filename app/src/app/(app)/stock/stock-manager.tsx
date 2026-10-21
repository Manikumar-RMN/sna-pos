"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { recordStock, saveIngredient, saveRecipe, type StockResult } from "./actions";

export type Level = { id: string; name: string; unit: string; cost: number; reorder: number; stock: number; used: number; wasted: number; bought: number; count_diff: number; category: string | null };
export type FoodCost = { product: string; price: number; cost: number; cost_pct: number | null };
type Product = { id: string; name: string; price: number };
type RecipeRow = { product_id: string; ingredient_id: string; qty: number };

const UNITS = ["kg", "g", "l", "ml", "pcs", "pack"];
const n2 = (x: number) => (Math.round(Number(x) * 1000) / 1000).toString();

export function StockManager({ currency, levels, foodCost, products, recipes }: { currency: string; levels: Level[]; foodCost: FoodCost[]; products: Product[]; recipes: RecipeRow[] }) {
  const router = useRouter();
  const [tab, setTab] = useState<"levels" | "recipes" | "cost">("levels");
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

  // Stock action on one ingredient.
  const [act, setAct] = useState<{ id: string; kind: "purchase" | "wastage" | "count" } | null>(null);
  const [qty, setQty] = useState("");
  const [cost, setCost] = useState("");
  const [note, setNote] = useState("");
  // New / edit ingredient.
  const [edit, setEdit] = useState<{ id: string | null; name: string; unit: string; cost: string; reorder: string; category: string } | null>(null);
  // Recipe editor.
  const [recipeFor, setRecipeFor] = useState<string>("");
  const [recipeRows, setRecipeRows] = useState<{ ingredient_id: string; qty: string }[]>([]);

  const low = levels.filter((l) => Number(l.stock) <= Number(l.reorder) && Number(l.reorder) > 0);
  // Groups already in use, offered as suggestions when typing a group.
  const groups = Array.from(new Set(levels.map((l) => (l.category ?? "").trim()).filter(Boolean))).sort((a, b) => a.localeCompare(b));

  function openRecipe(pid: string) {
    setRecipeFor(pid);
    setRecipeRows(recipes.filter((r) => r.product_id === pid).map((r) => ({ ingredient_id: r.ingredient_id, qty: String(r.qty) })));
  }

  return (
    <div className="space-y-4">
      <div className="flex gap-1.5">
        {(
          [
            ["levels", "Stock levels"],
            ["recipes", "Recipes"],
            ["cost", "Food cost"],
          ] as const
        ).map(([k, label]) => (
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
                <b style={{ color: "var(--color-warn)" }}>Running low:</b> {low.map((l) => `${l.name} (${n2(l.stock)} ${l.unit})`).join(", ")}
              </div>
              <Link href="/purchases?tab=orders&low=1" className="btn btn-primary h-10 min-h-0 shrink-0 px-4 text-sm">
                Order low stock
              </Link>
            </div>
          )}
          <div className="card overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr style={{ color: "var(--color-ink-3)" }}>
                  <th className="px-3 py-2 text-left text-xs font-semibold">Ingredient</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">In stock</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Used (7 days)</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Wasted</th>
                  <th className="px-3 py-2 text-right text-xs font-semibold">Cost / unit</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody>
                {levels.length === 0 && (
                  <tr>
                    <td colSpan={6} className="px-3 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                      No ingredients yet. Add one below.
                    </td>
                  </tr>
                )}
                {levels.map((l) => {
                  const isLow = Number(l.reorder) > 0 && Number(l.stock) <= Number(l.reorder);
                  return (
                    <tr key={l.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                      <td className="px-3 py-2">
                        <button className="text-left font-semibold" onClick={() => setEdit({ id: l.id, name: l.name, unit: l.unit, cost: String(l.cost), reorder: String(l.reorder), category: l.category ?? "" })}>
                          {l.name}
                        </button>
                        {l.category && (
                          <span className="ml-2 inline-block rounded-full px-2 py-0.5 text-[11px] font-semibold" style={{ background: "var(--color-ground)", color: "var(--color-ink-3)" }}>
                            {l.category}
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums" style={{ color: isLow ? "var(--color-bad)" : undefined, fontWeight: isLow ? 700 : 400 }}>
                        {n2(l.stock)} {l.unit}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums">{n2(l.used)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{n2(l.wasted)}</td>
                      <td className="px-3 py-2 text-right tabular-nums">{m(l.cost)}</td>
                      <td className="px-3 py-2 text-right">
                        <div className="flex justify-end gap-1">
                          {(["purchase", "wastage", "count"] as const).map((k) => (
                            <button
                              key={k}
                              className="rounded-md border px-2 py-1 text-[11px] font-semibold"
                              style={{ borderColor: act?.id === l.id && act.kind === k ? "var(--color-brand)" : "var(--color-line)" }}
                              onClick={() => {
                                setAct({ id: l.id, kind: k });
                                setQty("");
                                setCost("");
                                setNote("");
                              }}
                            >
                              {k === "purchase" ? "+ Bought" : k === "wastage" ? "Wasted" : "Count"}
                            </button>
                          ))}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          {act && (
            <section className="card p-4">
              <h2 className="text-sm font-bold">
                {act.kind === "purchase" ? "Record a purchase" : act.kind === "wastage" ? "Record wastage" : "Record a stock count"} —{" "}
                {levels.find((l) => l.id === act.id)?.name}
              </h2>
              <div className="mt-3 grid gap-2 sm:grid-cols-3">
                <input className="field h-10 text-sm" inputMode="decimal" placeholder={act.kind === "count" ? "Quantity you counted" : "Quantity"} value={qty} onChange={(e) => setQty(e.target.value)} />
                {act.kind === "purchase" && <input className="field h-10 text-sm" inputMode="decimal" placeholder="Price per unit (optional)" value={cost} onChange={(e) => setCost(e.target.value)} />}
                <input className="field h-10 text-sm" placeholder="Note (supplier, reason…)" value={note} onChange={(e) => setNote(e.target.value)} />
              </div>
              <div className="mt-3 flex gap-2">
                <button className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setAct(null)}>
                  Cancel
                </button>
                <button
                  className="btn btn-primary px-4 text-sm"
                  disabled={pending || qty === "" || !(Number(qty) >= 0)}
                  onClick={() => run(() => recordStock({ ingredientId: act.id, kind: act.kind, qty: Number(qty), unitCost: cost === "" ? null : Number(cost), note }), () => setAct(null))}
                >
                  {pending ? "Saving…" : "Save"}
                </button>
              </div>
            </section>
          )}

          {edit ? (
            <section className="card p-4">
              <h2 className="text-sm font-bold">{edit.id ? "Edit ingredient" : "New ingredient"}</h2>
              <div className="mt-3 grid gap-2 sm:grid-cols-4">
                <input className="field h-10 text-sm sm:col-span-2" placeholder="Name, e.g. Dosa batter" value={edit.name} onChange={(e) => setEdit({ ...edit, name: e.target.value })} maxLength={60} />
                <select className="field h-10 text-sm" value={edit.unit} onChange={(e) => setEdit({ ...edit, unit: e.target.value })} aria-label="Unit">
                  {UNITS.map((u) => (
                    <option key={u}>{u}</option>
                  ))}
                </select>
                <input className="field h-10 text-sm" inputMode="decimal" placeholder="Cost per unit" value={edit.cost} onChange={(e) => setEdit({ ...edit, cost: e.target.value })} />
                <input className="field h-10 text-sm sm:col-span-2" inputMode="decimal" placeholder="Warn when stock falls to (optional)" value={edit.reorder} onChange={(e) => setEdit({ ...edit, reorder: e.target.value })} />
                <input
                  className="field h-10 text-sm sm:col-span-2"
                  placeholder="Group, e.g. Vegetables (optional)"
                  aria-label="Group (optional)"
                  list="ingredient-groups"
                  value={edit.category}
                  onChange={(e) => setEdit({ ...edit, category: e.target.value })}
                  maxLength={40}
                />
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
                  onClick={() => run(() => saveIngredient({ id: edit.id, name: edit.name, unit: edit.unit, cost: Number(edit.cost) || 0, reorder: Number(edit.reorder) || 0, category: edit.category }), () => setEdit(null))}
                >
                  {pending ? "Saving…" : "Save ingredient"}
                </button>
              </div>
            </section>
          ) : (
            <button className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setEdit({ id: null, name: "", unit: "kg", cost: "", reorder: "", category: "" })}>
              + Add ingredient
            </button>
          )}
        </>
      )}

      {tab === "recipes" && (
        <section className="card p-4">
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            For each dish, say how much of each ingredient one portion uses. Dishes without a recipe do not change stock.
          </p>
          <select className="field mt-3 h-10 text-sm" value={recipeFor} onChange={(e) => openRecipe(e.target.value)} aria-label="Dish">
            <option value="">Choose a dish…</option>
            {products.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
                {recipes.some((r) => r.product_id === p.id) ? " ✓" : ""}
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
                      {levels.map((l) => (
                        <option key={l.id} value={l.id}>
                          {l.name} ({l.unit})
                        </option>
                      ))}
                    </select>
                    <input
                      className="field h-10 w-28 shrink-0 text-sm"
                      style={{ flex: "none", width: 96 }}
                      inputMode="decimal"
                      placeholder="Qty"
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
                  <td className="px-3 py-2 text-right font-semibold tabular-nums" style={{ color: Number(f.cost_pct) > 35 ? "var(--color-bad)" : "var(--color-ok)" }}>
                    {f.cost_pct == null ? "—" : `${f.cost_pct}%`}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="px-3 py-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Most restaurants aim for 25–35%. Costs use the latest purchase prices.
          </p>
        </div>
      )}
    </div>
  );
}
