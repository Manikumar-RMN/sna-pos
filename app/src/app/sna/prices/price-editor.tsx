"use client";

import { useState, useTransition } from "react";
import { setPrice } from "../actions";

export function PriceEditor({ items, currencies, initial }: { items: { key: string; name: string }[]; currencies: string[]; initial: Record<string, string> }) {
  const [pending, start] = useTransition();
  const [values, setValues] = useState(initial);
  const [msg, setMsg] = useState<string | null>(null);
  const save = (item: string, cur: string) =>
    start(async () => {
      const r = await setPrice(item, cur, values[`${item}|${cur}`] ?? "");
      setMsg(r.ok ? `${item} ${cur}: saved` : r.error);
    });
  return (
    <div className="mt-4">
      {msg && <div className="card mb-3 p-3 text-sm font-semibold">{msg}</div>}
      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr style={{ color: "var(--color-ink-3)" }}>
              <th className="px-3 py-2 text-left">Item</th>
              {currencies.map((c) => (
                <th key={c} className="px-3 py-2 text-left">
                  {c}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {items.map((it) => (
              <tr key={it.key} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                <td className="px-3 py-2 font-semibold">{it.name}</td>
                {currencies.map((c) => {
                  const k = `${it.key}|${c}`;
                  return (
                    <td key={c} className="px-3 py-2">
                      <input
                        className="field h-9 w-24"
                        inputMode="decimal"
                        value={values[k] ?? ""}
                        disabled={pending}
                        onChange={(e) => setValues({ ...values, [k]: e.target.value })}
                        onBlur={() => (values[k] ?? "") !== (initial[k] ?? "") && save(it.key, c)}
                      />
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
