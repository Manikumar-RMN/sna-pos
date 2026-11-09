"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState, useTransition } from "react";
import { money } from "@/lib/format";
import { buildStockInLines, fmtQty, stockInTotal, type BuyUnits, type IngredientLite, type StockInRow } from "@/lib/stock";
import { useOnline } from "@/lib/use-online";
import { stockInQuick } from "./actions";

const blankRow = (ingredient_id = ""): StockInRow => ({ ingredient_id, qty: "", cost: "" });

/** Quick stock-in: the simple way to record what was bought. One receipt, several ingredients. */
export function StockIn({ currency, ingredients, presetIngredient, buyUnits = {} }: { currency: string; ingredients: IngredientLite[]; presetIngredient?: string; buyUnits?: BuyUnits }) {
  const router = useRouter();
  const online = useOnline();
  const [pending, start] = useTransition();
  const [rows, setRows] = useState<StockInRow[]>([blankRow(presetIngredient), blankRow(), blankRow()]);
  const [supplier, setSupplier] = useState("");
  const [billRef, setBillRef] = useState("");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  // One reference per receipt: a double tap or a retry sends the same one, so the database records it once.
  const clientRef = useRef<string>(crypto.randomUUID());
  const byId = new Map(ingredients.map((i) => [i.id, i]));

  const built = buildStockInLines(rows);
  const total = built.ok ? stockInTotal(built.lines) : 0;

  function setRow(i: number, patch: Partial<StockInRow>) {
    setRows(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  }

  function save() {
    if (!built.ok) {
      setMsg({ ok: false, text: built.error });
      return;
    }
    setMsg(null);
    start(async () => {
      const r = await stockInQuick({ lines: built.lines, supplierNote: supplier, billRef, clientRef: clientRef.current });
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
      if (r.ok) {
        clientRef.current = crypto.randomUUID();
        setRows([blankRow(), blankRow(), blankRow()]);
        setSupplier("");
        setBillRef("");
        router.refresh();
      }
    });
  }

  return (
    <section className="card p-4">
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="text-sm font-bold">Stock in</h2>
          <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Record what you bought. The cost of each ingredient is averaged with what you already have.
          </p>
        </div>
        <Link href="/purchases" className="text-xs font-semibold underline" style={{ color: "var(--color-brand)" }}>
          Full purchase orders
        </Link>
      </div>

      <ul className="mt-3 space-y-2">
        {rows.map((r, i) => {
          const ing = byId.get(r.ingredient_id);
          const bu = ing ? buyUnits[ing.id] : undefined;
          const shownUnit = r.buy && bu ? bu.unit : ing?.unit;
          return (
            <li key={i} className="grid grid-cols-[minmax(0,1fr)_88px_96px_auto] items-center gap-2">
              <select
                className="field h-10 min-w-0 text-sm"
                style={{ textOverflow: "ellipsis" }}
                value={r.ingredient_id}
                onChange={(e) => {
                  const pick = byId.get(e.target.value);
                  setRow(i, { ingredient_id: e.target.value, buy: false, cost: r.cost === "" && pick && pick.cost > 0 ? fmtQty(pick.cost) : r.cost });
                }}
                aria-label="Ingredient"
              >
                <option value="">Ingredient…</option>
                {ingredients.map((x) => (
                  <option key={x.id} value={x.id}>
                    {x.name} ({x.unit})
                  </option>
                ))}
              </select>
              <input className="field h-10 text-sm" inputMode="decimal" placeholder={ing ? `Qty (${shownUnit})` : "Qty"} value={r.qty} onChange={(e) => setRow(i, { qty: e.target.value })} aria-label="Quantity bought" />
              <input className="field h-10 text-sm" inputMode="decimal" placeholder={ing ? `Price / ${shownUnit}` : "Price / unit"} value={r.cost} onChange={(e) => setRow(i, { cost: e.target.value })} aria-label="Price per unit" />
              <button className="px-2 text-sm font-bold" style={{ color: "var(--color-bad)" }} onClick={() => setRows(rows.length > 1 ? rows.filter((_, j) => j !== i) : [blankRow()])} aria-label="Remove line">
                ×
              </button>
              {ing && bu && (
                <div className="col-span-full flex items-center gap-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                  <span>Entering in</span>
                  <select
                    className="field h-8 w-auto text-xs"
                    value={r.buy ? "buy" : "stock"}
                    onChange={(e) => setRow(i, { buy: e.target.value === "buy", qty: "", cost: "" })}
                    aria-label="Unit for this line"
                  >
                    <option value="stock">{ing.unit}</option>
                    <option value="buy">{bu.unit} (1 {bu.unit} = {fmtQty(bu.factor)} {ing.unit})</option>
                  </select>
                </div>
              )}
            </li>
          );
        })}
      </ul>
      <button className="btn mt-2 border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setRows([...rows, blankRow()])}>
        + Another ingredient
      </button>

      <div className="mt-3 grid gap-2 sm:grid-cols-2">
        <input className="field h-10 text-sm" placeholder="Supplier (optional)" value={supplier} onChange={(e) => setSupplier(e.target.value)} maxLength={120} />
        <input className="field h-10 text-sm" placeholder="Bill number (optional)" value={billRef} onChange={(e) => setBillRef(e.target.value)} maxLength={60} />
      </div>

      <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
        <div className="text-sm">
          Total value <b className="tabular-nums">{money(total, currency)}</b>
        </div>
        <button className="btn btn-primary px-5 text-sm" disabled={pending || !online || !built.ok} onClick={save}>
          {pending ? "Saving…" : "Save stock in"}
        </button>
      </div>
      {!online && (
        <p className="mt-2 text-xs font-semibold" style={{ color: "var(--color-warn)" }}>
          Needs internet.
        </p>
      )}
      {msg && (
        <p className="mt-2 text-sm font-semibold" role={msg.ok ? "status" : "alert"} style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </p>
      )}
    </section>
  );
}
