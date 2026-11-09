"use client";

import { useState } from "react";
import { money } from "@/lib/format";
import { Badge, Field, lineStyle, Msg, rowBtn, useRun } from "../../purchases/ui";
import { closeMonth, reopenMonth, saveOpening } from "./actions";

type Ing = { id: string; name: string; unit: string; cost: number };
export type ClosureRow = { id: string; month: string; total: number; closedAt: string; revoked: boolean; revokeReason: string | null; lines: { name: string; unit: string; qty: number; value: number }[] };
const num = (s: string) => {
  const n = Number(s.trim());
  return Number.isFinite(n) && n > 0 ? n : 0;
};
const label = (m: string) => new Date(m + "T00:00:00Z").toLocaleDateString("en-GB", { month: "long", year: "numeric", timeZone: "UTC" });

/** Finished months from the first stock entry up to last month. */
function months(first: string | null): string[] {
  if (!first) return [];
  const out: string[] = [];
  const now = new Date();
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  let [y, m] = first.split("-").map(Number);
  let d = new Date(Date.UTC(y, m - 1, 1));
  while (d < end && out.length < 60) {
    out.push(d.toISOString().slice(0, 10));
    d = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1));
  }
  return out;
}

export function ClosingBoard({ canManage, isOwner, currency, firstMonth, ingredients, closures }: { canManage: boolean; isOwner: boolean; currency: string; firstMonth: string | null; ingredients: Ing[]; closures: ClosureRow[] }) {
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const [opening, setOpening] = useState(false);
  const done = (text: string) => {
    setOpening(false);
    setNote({ ok: true, text });
  };
  const m = (n: number) => money(n, currency);
  const active = new Set(closures.filter((c) => !c.revoked).map((c) => c.month));
  const todo = months(firstMonth).filter((x) => !active.has(x));
  const latest = closures.find((c) => !c.revoked)?.month;
  return (
    <div className="space-y-5">
      {canManage && (
        <div className="flex flex-wrap gap-2">
          <button type="button" className="btn btn-primary px-4 text-sm" onClick={() => setOpening(!opening)}>
            Enter opening stock
          </button>
        </div>
      )}
      <Msg msg={note} />
      {opening && <OpeningForm ingredients={ingredients} onDone={done} onClose={() => setOpening(false)} />}
      <section>
        <h2 className="mb-2 text-sm font-bold">Months to close</h2>
        <div className="card">
          {todo.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              Nothing to close. A month can be closed once it is over.
            </p>
          ) : (
            <ul>
              {todo.map((x, i) => (
                <CloseRow key={x} month={x} first={i === 0} canManage={canManage} onDone={done} />
              ))}
            </ul>
          )}
        </div>
      </section>
      <section>
        <h2 className="mb-2 text-sm font-bold">Closed months</h2>
        <div className="card">
          {closures.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              No month closed yet.
            </p>
          ) : (
            <ul>
              {closures.map((c, i) => (
                <ClosedItem key={c.id} c={c} first={i === 0} canReopen={isOwner && !c.revoked && c.month === latest} m={m} onDone={done} />
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
}

function CloseRow({ month, first, canManage, onDone }: { month: string; first: boolean; canManage: boolean; onDone: (t: string) => void }) {
  const run = useRun();
  return (
    <li className="px-4 py-3" style={first ? undefined : { borderTop: "1px solid var(--color-line)" }}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="font-semibold">{label(month)}</span>
        {canManage && (
          <button
            type="button"
            className={rowBtn}
            style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }}
            disabled={run.pending}
            onClick={() =>
              run.run(
                () => closeMonth(month),
                (x) => {
                  onDone(x.message);
                  return x.message;
                },
              )
            }
          >
            {run.pending ? "Closing…" : "Close month"}
          </button>
        )}
      </div>
      {run.msg && !run.msg.ok && <Msg msg={run.msg} />}
    </li>
  );
}

function ClosedItem({ c, first, canReopen, m, onDone }: { c: ClosureRow; first: boolean; canReopen: boolean; m: (n: number) => string; onDone: (t: string) => void }) {
  const run = useRun();
  const [show, setShow] = useState(false);
  const [ask, setAsk] = useState(false);
  const [reason, setReason] = useState("");
  return (
    <li className="px-4 py-3" style={first ? undefined : { borderTop: "1px solid var(--color-line)" }}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <span className="font-semibold">{label(c.month)}</span>{" "}
          {c.revoked ? <Badge label="Re-opened" bg="var(--color-warn-soft)" fg="var(--color-warn)" /> : <Badge label="Closed" bg="var(--color-ok-soft)" fg="var(--color-ok)" />}
          <div className="text-sm" style={{ color: "var(--color-ink-2)" }}>
            Closing stock {m(c.total)} · closed {c.closedAt.slice(0, 10)}
            {c.revokeReason ? ` · re-opened: ${c.revokeReason}` : ""}
          </div>
        </div>
        <div className="flex gap-2">
          <button type="button" className={rowBtn} style={lineStyle} onClick={() => setShow(!show)}>
            {show ? "Hide" : "Show stock"}
          </button>
          {canReopen && (
            <button type="button" className={rowBtn} style={{ ...lineStyle, color: "var(--color-bad)" }} onClick={() => setAsk(!ask)}>
              Re-open
            </button>
          )}
        </div>
      </div>
      {show && (
        <ul className="mt-2 text-sm" style={{ color: "var(--color-ink-2)" }}>
          {c.lines.length === 0 ? <li>No stock at the end of this month.</li> : c.lines.map((l, i) => (
            <li key={i} className="flex justify-between gap-3">
              <span>{l.name}: {l.qty} {l.unit}</span>
              <span className="tabular-nums">{m(l.value)}</span>
            </li>
          ))}
        </ul>
      )}
      {ask && (
        <div className="mt-3 rounded-2xl border p-3" style={{ borderColor: "var(--color-bad)", background: "var(--color-bad-soft)" }}>
          <Field label="Why is it being re-opened?">
            <input className="field h-10 text-sm" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} disabled={run.pending} />
          </Field>
          <div className="mt-2">
            <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
          </div>
          <div className="mt-3 flex gap-2">
            <button
              type="button"
              className="btn px-4 text-sm"
              style={{ background: "var(--color-bad)", color: "#fff" }}
              disabled={run.pending || reason.trim().length < 3}
              onClick={() =>
                run.run(
                  () => reopenMonth(c.id, reason),
                  (x) => {
                    setAsk(false);
                    onDone(x.message);
                    return x.message;
                  },
                )
              }
            >
              Re-open month
            </button>
            <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={() => setAsk(false)} disabled={run.pending}>
              Keep it closed
            </button>
          </div>
        </div>
      )}
    </li>
  );
}

function OpeningForm({ ingredients, onDone, onClose }: { ingredients: Ing[]; onDone: (t: string) => void; onClose: () => void }) {
  const run = useRun();
  const [rows, setRows] = useState<{ id: string; qty: string; cost: string }[]>([{ id: "", qty: "", cost: "" }, { id: "", qty: "", cost: "" }, { id: "", qty: "", cost: "" }]);
  const set = (i: number, p: Partial<{ id: string; qty: string; cost: string }>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...p } : r)));
  function save() {
    if (rows.some((r) => (r.id && !num(r.qty)) || (!r.id && (r.qty.trim() !== "" || r.cost.trim() !== "")))) return run.setMsg({ ok: false, text: "Finish or clear every line first." });
    const lines = rows.filter((r) => r.id && num(r.qty) > 0).map((r) => ({ ingredient_id: r.id, qty: num(r.qty), ...(num(r.cost) > 0 ? { unit_cost: num(r.cost) } : {}) }));
    if (lines.length === 0) return run.setMsg({ ok: false, text: "Add at least one ingredient with a quantity." });
    if (new Set(lines.map((l) => l.ingredient_id)).size !== lines.length) return run.setMsg({ ok: false, text: "An ingredient is on the list twice. Put it on one line." });
    run.run(
      () => saveOpening(lines),
      (x) => {
        onDone(x.message);
        return x.message;
      },
    );
  }
  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Opening stock</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Only ingredients with no stock entries yet are listed. Once an ingredient has any entry, correct it with a stock count instead.
      </p>
      {ingredients.length === 0 ? (
        <p className="mt-3 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Every ingredient already has stock entries.
        </p>
      ) : (
        <>
          <ul className="mt-3 space-y-2">
            {rows.map((r, i) => {
              const ing = ingredients.find((x) => x.id === r.id);
              return (
                <li key={i} className="grid grid-cols-[minmax(0,1fr)_96px_96px_auto] items-center gap-2">
                  <select className="field h-10 min-w-0 text-sm" value={r.id} onChange={(e) => set(i, { id: e.target.value })} aria-label="Ingredient" disabled={run.pending}>
                    <option value="">Ingredient…</option>
                    {ingredients.map((x) => (
                      <option key={x.id} value={x.id}>
                        {x.name} ({x.unit})
                      </option>
                    ))}
                  </select>
                  <input className="field h-10 text-sm" inputMode="decimal" placeholder={ing ? `Qty (${ing.unit})` : "Qty"} aria-label="Quantity" value={r.qty} onChange={(e) => set(i, { qty: e.target.value })} disabled={run.pending} />
                  <input className="field h-10 text-sm" inputMode="decimal" placeholder={ing && ing.cost > 0 ? `Cost ${ing.cost}` : "Cost each"} aria-label="Cost per unit" value={r.cost} onChange={(e) => set(i, { cost: e.target.value })} disabled={run.pending} />
                  <button type="button" className="px-2 text-sm font-bold" style={{ color: "var(--color-bad)" }} onClick={() => setRows(rows.length > 1 ? rows.filter((_, j) => j !== i) : [{ id: "", qty: "", cost: "" }])} aria-label="Remove line">
                    ×
                  </button>
                </li>
              );
            })}
          </ul>
          <button type="button" className="btn mt-2 border px-4 text-sm" style={lineStyle} onClick={() => setRows([...rows, { id: "", qty: "", cost: "" }])}>
            + Another ingredient
          </button>
        </>
      )}
      <div className="mt-2">
        <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        {ingredients.length > 0 && (
          <button type="button" className="btn btn-primary px-5 text-sm" onClick={save} disabled={run.pending}>
            {run.pending ? "Saving…" : "Save opening stock"}
          </button>
        )}
        <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={run.pending}>
          Close
        </button>
      </div>
    </section>
  );
}
