"use client";

import { useState, useTransition } from "react";
import { moveToTaxGroup, type TaxMoveResult } from "./actions";

export function BulkTax({ categories, taxGroups }: { categories: { id: string; name: string }[]; taxGroups: { id: string; name: string }[] }) {
  const [cat, setCat] = useState("");
  const [tax, setTax] = useState("");
  const [why, setWhy] = useState("");
  const [res, setRes] = useState<TaxMoveResult | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function run(apply: boolean) {
    setDone(null);
    start(async () => {
      const r = await moveToTaxGroup({ categoryId: cat || null, taxGroupId: tax, apply, reason: why });
      if (apply && r.ok) {
        setDone(`${r.toChange} dish${r.toChange === 1 ? "" : "es"} moved to ${r.taxGroup}.`);
        setRes(null);
      } else setRes(r);
    });
  }

  return (
    <div className="card space-y-3 p-4">
      <label className="block text-xs font-medium">
        Menu group
        <select className="field mt-1 h-10 w-full text-sm" value={cat} onChange={(e) => { setCat(e.target.value); setRes(null); }}>
          <option value="">Every dish on the menu</option>
          {categories.map((c) => (
            <option key={c.id} value={c.id}>{c.name}</option>
          ))}
        </select>
      </label>
      <label className="block text-xs font-medium">
        New tax group
        <select className="field mt-1 h-10 w-full text-sm" value={tax} onChange={(e) => { setTax(e.target.value); setRes(null); }}>
          <option value="">Choose…</option>
          {taxGroups.map((t) => (
            <option key={t.id} value={t.id}>{t.name}</option>
          ))}
        </select>
      </label>
      <button className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} disabled={pending || !tax} onClick={() => run(false)}>
        {pending ? "Checking…" : "See how many dishes change"}
      </button>
      {res && !res.ok && <p className="text-sm" role="alert" style={{ color: "var(--color-danger, #B3261E)" }}>{res.error}</p>}
      {res && res.ok && (
        <div className="space-y-2 rounded-lg border p-3 text-sm" style={{ borderColor: "var(--color-line)" }}>
          <p>
            <b>{res.toChange}</b> of {res.total} dishes would move to <b>{res.taxGroup}</b>.
            {res.toChange === 0 && " Nothing to change."}
          </p>
          {res.toChange > 0 && (
            <>
              <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                A tax group that includes tax in the price (or not) changes what the guest pays for a new order. Check it before you apply.
              </p>
              <input className="field h-10 w-full text-sm" placeholder="Reason for the change (needed)" maxLength={200} value={why} onChange={(e) => setWhy(e.target.value)} />
              <button className="btn btn-primary w-full text-sm" disabled={pending || why.trim().length < 3} onClick={() => run(true)}>
                {pending ? "Applying…" : `Move ${res.toChange} dishes`}
              </button>
            </>
          )}
        </div>
      )}
      {done && <p className="text-sm font-semibold" role="status">{done}</p>}
    </div>
  );
}
