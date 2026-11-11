"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { saveNcTarget } from "./actions";

export type NcRow = { id: string; name: string; is_active: boolean };

export function NcCharge({ rows }: { rows: NcRow[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [name, setName] = useState("");
  const [editId, setEditId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  function save(input: { id: string | null; name: string; active: boolean }, after?: () => void) {
    setError(null);
    start(async () => {
      const r = await saveNcTarget(input);
      if (r.error) return setError(r.error);
      after?.();
      router.refresh();
    });
  }

  return (
    <div className="card p-4">
      <div className="flex flex-wrap gap-2">
        <input className="field h-10 min-w-0 flex-1 text-sm" placeholder={editId ? "New name" : "Add an account, e.g. Admin & General"} aria-label="Account name" maxLength={60} value={name} onChange={(e) => setName(e.target.value)} />
        <button
          className="btn btn-primary px-4 text-sm"
          disabled={pending || name.trim().length < 2}
          onClick={() => save({ id: editId, name: name.trim(), active: rows.find((r) => r.id === editId)?.is_active ?? true }, () => { setName(""); setEditId(null); })}
        >
          {editId ? "Rename" : "Add"}
        </button>
        {editId && (
          <button className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => { setEditId(null); setName(""); }}>
            Cancel
          </button>
        )}
      </div>
      {error && <p className="mt-2 text-sm" style={{ color: "var(--color-danger, #B3261E)" }} role="alert">{error}</p>}
      <div className="mt-3">
        {rows.length === 0 ? (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>None yet. Staff are not asked who a no-charge bill is charged to.</p>
        ) : (
          rows.map((r) => (
            <div key={r.id} className="flex items-center gap-3 py-2" style={{ borderTop: "1px solid var(--color-line)", opacity: r.is_active ? 1 : 0.55 }}>
              <div className="min-w-0 flex-1 text-sm font-semibold">
                {r.name}
                {!r.is_active && <span className="ml-2 text-[11px] font-normal">(switched off)</span>}
              </div>
              <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => { setEditId(r.id); setName(r.name); }}>
                Rename
              </button>
              <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} disabled={pending} onClick={() => save({ id: r.id, name: r.name, active: !r.is_active })}>
                {r.is_active ? "Switch off" : "Switch on"}
              </button>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
