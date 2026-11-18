"use client";

import { useState, useTransition } from "react";
import { setPrice } from "../actions";

/** One currency at a time, so the page never scrolls sideways. A saved price is written when you leave the box. */
export function PriceEditor({ items, currencies, initial }: { items: { key: string; name: string }[]; currencies: string[]; initial: Record<string, string> }) {
  const [pending, start] = useTransition();
  const [values, setValues] = useState(initial);
  const [saved, setSaved] = useState(initial);
  const [cur, setCur] = useState(currencies.includes("INR") ? "INR" : (currencies[0] ?? ""));
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const unpriced = (c: string) => items.filter((it) => !(values[`${it.key}|${c}`] ?? "").trim()).length;

  const save = (item: string, c: string, name: string) =>
    start(async () => {
      const k = `${item}|${c}`;
      const r = await setPrice(item, c, values[k] ?? "");
      if (r.ok) {
        setSaved((s) => ({ ...s, [k]: values[k] ?? "" }));
        setMsg({ ok: true, text: `${name} in ${c}: saved` });
      } else setMsg({ ok: false, text: r.error });
    });

  return (
    <div className="mt-4 space-y-3">
      <nav aria-label="Currency" className="flex flex-wrap gap-1">
        {currencies.map((c) => {
          const on = c === cur;
          const n = unpriced(c);
          return (
            <button
              key={c}
              type="button"
              aria-pressed={on}
              onClick={() => setCur(c)}
              className="rounded-full border px-3 py-1.5 text-xs font-bold"
              style={on ? { background: "var(--color-ink)", color: "#fff", borderColor: "var(--color-ink)" } : { borderColor: "var(--color-line)", color: "var(--color-ink-2)", background: "var(--color-surface)" }}
            >
              {c}
              {n > 0 && <span className="ml-1.5 opacity-70">{n} not priced</span>}
            </button>
          );
        })}
      </nav>

      {msg && (
        <div role={msg.ok ? "status" : "alert"} className="card p-3 text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </div>
      )}

      <div className="card overflow-hidden">
        <div className="px-4 py-3 text-sm font-bold" style={{ borderBottom: "1px solid var(--color-line)" }}>
          Prices in {cur} per month
        </div>
        <ul className="divide-y" style={{ borderColor: "var(--color-line)" }}>
          {items.map((it) => {
            const k = `${it.key}|${cur}`;
            const empty = !(values[k] ?? "").trim();
            return (
              <li key={it.key} className="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                <div>
                  <div className="text-sm font-semibold">{it.name}</div>
                  {empty && (
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                      Not priced yet
                    </div>
                  )}
                </div>
                <label className="flex items-center gap-2 text-sm">
                  <span className="sr-only">
                    {it.name} price in {cur}
                  </span>
                  <span style={{ color: "var(--color-ink-3)" }}>{cur}</span>
                  <input
                    className="field h-10 w-32 text-right"
                    inputMode="decimal"
                    placeholder="—"
                    value={values[k] ?? ""}
                    disabled={pending}
                    onChange={(e) => setValues({ ...values, [k]: e.target.value })}
                    onBlur={() => (values[k] ?? "") !== (saved[k] ?? "") && save(it.key, cur, it.name)}
                  />
                </label>
              </li>
            );
          })}
        </ul>
      </div>
    </div>
  );
}
