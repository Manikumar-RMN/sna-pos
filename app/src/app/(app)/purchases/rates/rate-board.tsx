"use client";

import { useState } from "react";
import { money } from "@/lib/format";
import { Field, Msg, lineStyle, rowBtn, useRun } from "../ui";
import { saveRate, stopRate } from "./actions";

export type RateRow = { id: string; supplier: string; item: string; unit: string; rate: number; from: string; to: string | null; notes: string | null };

export function RateBoard({ canManage, currency, today, suppliers, ingredients, rates }: { canManage: boolean; currency: string; today: string; suppliers: { id: string; name: string }[]; ingredients: { id: string; name: string; unit: string }[]; rates: RateRow[] }) {
  const { pending, msg, run } = useRun();
  const [supplierId, setSupplierId] = useState("");
  const [ingredientId, setIngredientId] = useState("");
  const [rate, setRate] = useState("");
  const [from, setFrom] = useState(today);
  const [to, setTo] = useState("");
  const [notes, setNotes] = useState("");
  const unit = ingredients.find((i) => i.id === ingredientId)?.unit ?? "";
  const [filter, setFilter] = useState("");
  const shown = rates.filter((r) => !filter || r.supplier === filter);
  const supplierNames = Array.from(new Set(rates.map((r) => r.supplier)));

  function save() {
    run(
      () => saveRate({ supplierId, ingredientId, rate, from, to, notes }),
      () => {
        setIngredientId("");
        setRate("");
        setTo("");
        setNotes("");
      },
    );
  }

  return (
    <div className="space-y-5">
      {canManage && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">New agreed rate</h2>
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <Field label="Supplier">
              <select className="field h-10 text-sm" value={supplierId} onChange={(e) => setSupplierId(e.target.value)} disabled={pending}>
                <option value="">Choose a supplier…</option>
                {suppliers.map((s) => (
                  <option key={s.id} value={s.id}>
                    {s.name}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Ingredient">
              <select className="field h-10 text-sm" value={ingredientId} onChange={(e) => setIngredientId(e.target.value)} disabled={pending}>
                <option value="">Choose an ingredient…</option>
                {ingredients.map((i) => (
                  <option key={i.id} value={i.id}>
                    {i.name} ({i.unit})
                  </option>
                ))}
              </select>
            </Field>
          </div>
          <div className="mt-3 grid gap-3 sm:grid-cols-4">
            <Field label={`Agreed rate${unit ? ` per ${unit}` : ""}`}>
              <input className="field h-10 text-sm" inputMode="decimal" placeholder="0.00" value={rate} onChange={(e) => setRate(e.target.value)} disabled={pending} />
            </Field>
            <Field label="From">
              <input className="field h-10 text-sm" type="date" value={from} onChange={(e) => setFrom(e.target.value)} disabled={pending} />
            </Field>
            <Field label="Until" hint="(optional)">
              <input className="field h-10 text-sm" type="date" min={from} value={to} onChange={(e) => setTo(e.target.value)} disabled={pending} />
            </Field>
            <Field label="Note" hint="(optional)">
              <input className="field h-10 text-sm" value={notes} maxLength={200} onChange={(e) => setNotes(e.target.value)} disabled={pending} />
            </Field>
          </div>
          <div className="mt-3 flex items-center gap-3">
            <button type="button" className="btn btn-primary px-4 text-sm" onClick={save} disabled={pending}>
              {pending ? "Saving…" : "Save rate"}
            </button>
          </div>
        </section>
      )}
      <Msg msg={msg} />
      <section>
        <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
          <h2 className="text-sm font-bold">Agreed rates in force or coming</h2>
          {supplierNames.length > 1 && (
            <select className="field h-9 w-auto text-sm" value={filter} onChange={(e) => setFilter(e.target.value)} aria-label="Show one supplier">
              <option value="">All suppliers</option>
              {supplierNames.map((n) => (
                <option key={n} value={n}>
                  {n}
                </option>
              ))}
            </select>
          )}
        </div>
        <div className="card">
          {shown.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              No agreed rates yet.
            </p>
          ) : (
            <ul>
              {shown.map((r, i) => (
                <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm" style={i > 0 ? { borderTop: "1px solid var(--color-line)" } : undefined}>
                  <div className="min-w-0">
                    <div className="font-semibold">
                      {r.item} · {r.supplier}
                    </div>
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      From {r.from}
                      {r.to ? ` until ${r.to}` : " (no end date)"}
                      {r.notes ? ` · ${r.notes}` : ""}
                      {r.from > today ? " · not started yet" : r.to && r.to < today ? " · finished" : ""}
                    </div>
                  </div>
                  <div className="flex items-center gap-3">
                    <b className="tabular-nums">
                      {money(r.rate, currency)} / {r.unit}
                    </b>
                    {canManage && (
                      <button type="button" className={rowBtn} style={lineStyle} disabled={pending} onClick={() => run(() => stopRate(r.id))}>
                        Stop
                      </button>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
}
