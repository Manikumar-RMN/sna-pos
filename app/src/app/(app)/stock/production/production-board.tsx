"use client";

import { useRef, useState } from "react";
import { money } from "@/lib/format";
import { Confirm, Field, lineStyle, Msg, rowBtn, useRun } from "../../purchases/ui";
import { cancelPlan, deleteRecipe, planBatch, produce, saveRecipe } from "./actions";

type Ing = { id: string; name: string; unit: string; cost: number };
type RecipeLine = { ingredient_id: string; name: string; unit: string; cost: number; qty: number };
export type Recipe = { outputId: string; name: string; unit: string; yieldQty: number; note: string | null; lines: RecipeLine[] };
export type PlanRow = { id: string; number: string; outputId: string; name: string; unit: string; qty: number; forDate: string; note: string | null };
export type RunRow = { id: string; number: string; name: string; unit: string; qty: number; day: string; value: number };

type Mode = { kind: "none" } | { kind: "make"; outputId: string; runId: string | null; qty: number } | { kind: "plan" } | { kind: "recipe"; outputId: string | null };

const num = (s: string) => {
  const n = Number(s.trim());
  return Number.isFinite(n) && n > 0 ? n : 0;
};
const fmt = (n: number) => String(Math.round(n * 10000) / 10000);

export function ProductionBoard({ canManage, currency, ingredients, recipes, plans, done }: { canManage: boolean; currency: string; ingredients: Ing[]; recipes: Recipe[]; plans: PlanRow[]; done: RunRow[] }) {
  const [mode, setMode] = useState<Mode>({ kind: "none" });
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const m = (n: number) => money(n, currency);
  const finish = (text: string) => {
    setMode({ kind: "none" });
    setNote({ ok: true, text });
  };
  const planRun = useRun();
  const recipeFor = (id: string) => recipes.find((r) => r.outputId === id);

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap gap-2">
        {canManage && (
          <>
            <button type="button" className="btn btn-primary px-4 text-sm" onClick={() => setMode(mode.kind === "recipe" && mode.outputId === null ? { kind: "none" } : { kind: "recipe", outputId: null })}>
              Add a recipe
            </button>
            <button type="button" className="btn border px-4 text-sm" style={lineStyle} disabled={recipes.length === 0} onClick={() => setMode(mode.kind === "plan" ? { kind: "none" } : { kind: "plan" })}>
              Plan a batch
            </button>
          </>
        )}
      </div>
      <Msg msg={note} />

      {mode.kind === "recipe" && canManage && (
        <RecipeForm
          key={mode.outputId ?? "new"}
          ingredients={ingredients}
          taken={recipes.map((r) => r.outputId)}
          existing={mode.outputId ? recipeFor(mode.outputId) ?? null : null}
          currency={currency}
          onDone={finish}
          onClose={() => setMode({ kind: "none" })}
        />
      )}
      {mode.kind === "plan" && canManage && <PlanForm recipes={recipes} onDone={finish} onClose={() => setMode({ kind: "none" })} />}
      {mode.kind === "make" && canManage && recipeFor(mode.outputId) && (
        <MakeForm key={`${mode.outputId}:${mode.runId ?? "now"}`} recipe={recipeFor(mode.outputId)!} runId={mode.runId} startQty={mode.qty} currency={currency} onDone={finish} onClose={() => setMode({ kind: "none" })} />
      )}

      <section>
        <h2 className="mb-2 text-sm font-bold">Planned batches</h2>
        <div className="card">
          {plans.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              Nothing planned. Plan a batch for today or a later day, or make one straight from a recipe below.
            </p>
          ) : (
            <ul className="divide-y" style={{ borderColor: "var(--color-line)" }}>
              {plans.map((p) => (
                <li key={p.id} className="flex flex-wrap items-center gap-3 px-4 py-3">
                  <div className="min-w-0 flex-1">
                    <div className="text-sm font-semibold">
                      {p.name} · {fmt(p.qty)} {p.unit}
                    </div>
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      {p.number} · for {p.forDate}
                      {p.note ? ` · ${p.note}` : ""}
                    </div>
                  </div>
                  {canManage && (
                    <div className="flex flex-wrap items-center gap-2">
                      <button type="button" className={rowBtn} style={{ ...lineStyle, color: "var(--color-brand)" }} onClick={() => setMode({ kind: "make", outputId: p.outputId, runId: p.id, qty: p.qty })}>
                        Make it
                      </button>
                      <Confirm question="Cancel this plan?" yes="Cancel plan" no="Keep" onYes={() => planRun.run(() => cancelPlan(p.id))}>
                        Cancel
                      </Confirm>
                    </div>
                  )}
                </li>
              ))}
            </ul>
          )}
        </div>
        <div className="mt-2">
          <Msg msg={planRun.msg} />
        </div>
      </section>

      <section>
        <h2 className="mb-2 text-sm font-bold">Recipes</h2>
        <div className="card">
          {recipes.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              No recipes yet. Add the prepared item as an ingredient in Stock, then add its recipe here.
            </p>
          ) : (
            <ul className="divide-y" style={{ borderColor: "var(--color-line)" }}>
              {recipes.map((r) => {
                const cost = r.lines.reduce((t, l) => t + l.qty * l.cost, 0);
                return (
                  <li key={r.outputId} className="px-4 py-3">
                    <div className="flex flex-wrap items-center gap-3">
                      <div className="min-w-0 flex-1">
                        <div className="text-sm font-semibold">{r.name}</div>
                        <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                          One batch makes {fmt(r.yieldQty)} {r.unit} · about {m(cost)} ({m(r.yieldQty > 0 ? cost / r.yieldQty : 0)} per {r.unit}) at today&rsquo;s ingredient costs
                        </div>
                      </div>
                      {canManage && (
                        <div className="flex flex-wrap items-center gap-2">
                          <button type="button" className={`${rowBtn} btn-primary`} style={{ borderColor: "var(--color-brand)", background: "var(--color-brand)", color: "#fff" }} onClick={() => setMode({ kind: "make", outputId: r.outputId, runId: null, qty: r.yieldQty })}>
                            Make a batch
                          </button>
                          <button type="button" className={rowBtn} style={lineStyle} onClick={() => setMode({ kind: "recipe", outputId: r.outputId })}>
                            Edit
                          </button>
                        </div>
                      )}
                    </div>
                    <p className="mt-1 text-xs" style={{ color: "var(--color-ink-2)" }}>
                      {r.lines.map((l) => `${l.name} ${fmt(l.qty)} ${l.unit}`).join(" · ")}
                    </p>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </section>

      <section>
        <h2 className="mb-2 text-sm font-bold">Recently made</h2>
        <div className="card">
          {done.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              Nothing made yet.
            </p>
          ) : (
            <ul className="divide-y" style={{ borderColor: "var(--color-line)" }}>
              {done.map((d) => (
                <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 px-4 py-2.5 text-sm">
                  <span>
                    <span className="font-semibold">{d.name}</span> · {fmt(d.qty)} {d.unit}
                    <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      {" "}
                      · {d.number} · {d.day}
                    </span>
                  </span>
                  <span className="font-semibold">{m(d.value)}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
}

/** Make a batch: shows what it will use up and what it will cost before anything moves. */
function MakeForm({ recipe, runId, startQty, currency, onDone, onClose }: { recipe: Recipe; runId: string | null; startQty: number; currency: string; onDone: (t: string) => void; onClose: () => void }) {
  const run = useRun();
  const [qty, setQty] = useState(fmt(startQty));
  const [note, setNote] = useState("");
  const ref = useRef<string>(crypto.randomUUID());
  const q = num(qty);
  const scale = recipe.yieldQty > 0 ? q / recipe.yieldQty : 0;
  const total = recipe.lines.reduce((t, l) => t + l.qty * scale * l.cost, 0);
  const m = (n: number) => money(n, currency);
  function go() {
    if (q <= 0) return run.setMsg({ ok: false, text: "Enter how much was made." });
    run.run(
      () => produce({ runId, outputId: recipe.outputId, qty: q, date: "", note, clientRef: ref.current }),
      (x) => {
        ref.current = crypto.randomUUID();
        onDone(x.message);
        return x.message;
      },
      "Could not reach the server. Check the connection and tap the button again without changing anything — it will not be saved twice.",
    );
  }
  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Make {recipe.name}</h2>
      <Field label={`How much was made (${recipe.unit})`} className="mt-2 max-w-xs">
        <input className="field h-10 text-sm" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} disabled={run.pending} />
      </Field>
      <div className="mt-3 rounded-xl border p-3 text-sm" style={lineStyle}>
        <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
          This will use
        </div>
        <ul className="mt-1 space-y-0.5">
          {recipe.lines.map((l) => (
            <li key={l.ingredient_id} className="flex justify-between gap-3">
              <span>{l.name}</span>
              <span>
                {fmt(l.qty * scale)} {l.unit}
              </span>
            </li>
          ))}
        </ul>
        <div className="mt-2 flex justify-between border-t pt-2 font-semibold" style={lineStyle}>
          <span>Cost of the batch</span>
          <span>
            {m(total)}
            {q > 0 ? ` (${m(total / q)} per ${recipe.unit})` : ""}
          </span>
        </div>
      </div>
      <input className="field mt-3 h-10 text-sm" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} disabled={run.pending} />
      <div className="mt-2">
        <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <button type="button" className="btn btn-primary px-5 text-sm" onClick={go} disabled={run.pending || q <= 0}>
          {run.pending ? "Saving…" : "Make it"}
        </button>
        <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={run.pending}>
          Close
        </button>
      </div>
    </section>
  );
}

function PlanForm({ recipes, onDone, onClose }: { recipes: Recipe[]; onDone: (t: string) => void; onClose: () => void }) {
  const run = useRun();
  const [outputId, setOutputId] = useState(recipes[0]?.outputId ?? "");
  const [qty, setQty] = useState("");
  const [forDate, setForDate] = useState("");
  const [note, setNote] = useState("");
  const ref = useRef<string>(crypto.randomUUID());
  const r = recipes.find((x) => x.outputId === outputId);
  function go() {
    if (!outputId) return run.setMsg({ ok: false, text: "Choose the item to make." });
    if (num(qty) <= 0) return run.setMsg({ ok: false, text: "Enter how much to make." });
    run.run(
      () => planBatch({ outputId, qty: num(qty), forDate, note, clientRef: ref.current }),
      (x) => {
        ref.current = crypto.randomUUID();
        onDone(x.message);
        return x.message;
      },
    );
  }
  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Plan a batch</h2>
      <div className="mt-2 grid gap-3 sm:grid-cols-3">
        <Field label="Item">
          <select className="field h-10 text-sm" value={outputId} onChange={(e) => setOutputId(e.target.value)} disabled={run.pending}>
            {recipes.map((x) => (
              <option key={x.outputId} value={x.outputId}>
                {x.name}
              </option>
            ))}
          </select>
        </Field>
        <Field label={`How much (${r?.unit ?? ""})`}>
          <input className="field h-10 text-sm" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)} disabled={run.pending} />
        </Field>
        <Field label="For day" hint="(empty = today)">
          <input type="date" className="field h-10 text-sm" value={forDate} onChange={(e) => setForDate(e.target.value)} disabled={run.pending} />
        </Field>
      </div>
      <input className="field mt-3 h-10 text-sm" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} disabled={run.pending} />
      <div className="mt-2">
        <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <button type="button" className="btn btn-primary px-5 text-sm" onClick={go} disabled={run.pending}>
          {run.pending ? "Saving…" : "Add to the plan"}
        </button>
        <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={run.pending}>
          Close
        </button>
      </div>
    </section>
  );
}

function RecipeForm({ ingredients, taken, existing, currency, onDone, onClose }: { ingredients: Ing[]; taken: string[]; existing: Recipe | null; currency: string; onDone: (t: string) => void; onClose: () => void }) {
  const run = useRun();
  const choices = ingredients.filter((i) => i.id === existing?.outputId || !taken.includes(i.id));
  const [outputId, setOutputId] = useState(existing?.outputId ?? "");
  const [yieldQty, setYieldQty] = useState(existing ? fmt(existing.yieldQty) : "");
  const [rows, setRows] = useState<{ id: string; qty: string }[]>(
    existing ? existing.lines.map((l) => ({ id: l.ingredient_id, qty: fmt(l.qty) })) : [{ id: "", qty: "" }, { id: "", qty: "" }, { id: "", qty: "" }],
  );
  const [note, setNote] = useState(existing?.note ?? "");
  const set = (i: number, p: Partial<{ id: string; qty: string }>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...p } : r)));
  const out = ingredients.find((i) => i.id === outputId);
  const cost = rows.reduce((t, r) => t + num(r.qty) * (ingredients.find((i) => i.id === r.id)?.cost ?? 0), 0);

  function save() {
    const lines = rows.filter((r) => r.id && num(r.qty) > 0).map((r) => ({ ingredient_id: r.id, qty: num(r.qty) }));
    if (!outputId) return run.setMsg({ ok: false, text: "Choose the item that is being made." });
    if (num(yieldQty) <= 0) return run.setMsg({ ok: false, text: "Enter how much one batch makes." });
    if (rows.some((r) => (r.id && !num(r.qty)) || (!r.id && r.qty.trim() !== ""))) return run.setMsg({ ok: false, text: "Finish or clear every line first." });
    if (lines.length === 0) return run.setMsg({ ok: false, text: "Add at least one ingredient with a quantity." });
    if (new Set(lines.map((l) => l.ingredient_id)).size !== lines.length) return run.setMsg({ ok: false, text: "An ingredient is on the list twice. Put it on one line." });
    if (lines.some((l) => l.ingredient_id === outputId)) return run.setMsg({ ok: false, text: "An item cannot be made from itself." });
    run.run(
      () => saveRecipe({ outputId, yieldQty: num(yieldQty), lines, note }),
      (x) => {
        onDone(x.message);
        return x.message;
      },
    );
  }

  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">{existing ? `Recipe for ${existing.name}` : "Add a recipe"}</h2>
      <div className="mt-2 grid gap-3 sm:grid-cols-2">
        <Field label="Item that is made">
          <select className="field h-10 text-sm" value={outputId} onChange={(e) => setOutputId(e.target.value)} disabled={run.pending || !!existing}>
            <option value="">Choose…</option>
            {choices.map((i) => (
              <option key={i.id} value={i.id}>
                {i.name} ({i.unit})
              </option>
            ))}
          </select>
        </Field>
        <Field label={`One batch makes (${out?.unit ?? "unit"})`}>
          <input className="field h-10 text-sm" inputMode="decimal" placeholder="e.g. 10" value={yieldQty} onChange={(e) => setYieldQty(e.target.value)} disabled={run.pending} />
        </Field>
      </div>
      <h3 className="mt-4 text-xs font-bold" style={{ color: "var(--color-ink-3)" }}>
        Ingredients for one batch
      </h3>
      <ul className="mt-2 space-y-2">
        {rows.map((r, i) => {
          const ing = ingredients.find((x) => x.id === r.id);
          return (
            <li key={i} className="grid grid-cols-[minmax(0,1fr)_110px_auto] items-center gap-2">
              <select className="field h-10 min-w-0 text-sm" value={r.id} onChange={(e) => set(i, { id: e.target.value })} aria-label="Ingredient" disabled={run.pending}>
                <option value="">Ingredient…</option>
                {ingredients
                  .filter((x) => x.id !== outputId)
                  .map((x) => (
                    <option key={x.id} value={x.id}>
                      {x.name} ({x.unit})
                    </option>
                  ))}
              </select>
              <input className="field h-10 text-sm" inputMode="decimal" placeholder={ing ? `Qty (${ing.unit})` : "Qty"} aria-label="Quantity" value={r.qty} onChange={(e) => set(i, { qty: e.target.value })} disabled={run.pending} />
              <button type="button" className="px-2 text-sm font-bold" style={{ color: "var(--color-bad)" }} onClick={() => setRows(rows.length > 1 ? rows.filter((_, j) => j !== i) : [{ id: "", qty: "" }])} aria-label="Remove line">
                ×
              </button>
            </li>
          );
        })}
      </ul>
      <button type="button" className="btn mt-2 border px-4 text-sm" style={lineStyle} onClick={() => setRows([...rows, { id: "", qty: "" }])}>
        + Another ingredient
      </button>
      {cost > 0 && num(yieldQty) > 0 && (
        <p className="mt-3 text-sm" style={{ color: "var(--color-ink-2)" }}>
          One batch costs about {money(cost, currency)} ({money(cost / num(yieldQty), currency)} per {out?.unit ?? "unit"}) at today&rsquo;s ingredient costs.
        </p>
      )}
      <input className="field mt-3 h-10 text-sm" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} disabled={run.pending} />
      <div className="mt-2">
        <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button type="button" className="btn btn-primary px-5 text-sm" onClick={save} disabled={run.pending}>
          {run.pending ? "Saving…" : "Save recipe"}
        </button>
        <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={run.pending}>
          Close
        </button>
        {existing && (
          <Confirm question="Remove this recipe?" yes="Remove" no="Keep" onYes={() => run.run(() => deleteRecipe(existing.outputId), (x) => { onDone(x.message); return x.message; })}>
            Remove recipe
          </Confirm>
        )}
      </div>
    </section>
  );
}
