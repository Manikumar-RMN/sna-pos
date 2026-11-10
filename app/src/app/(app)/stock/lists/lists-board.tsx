"use client";

import { useState, useTransition } from "react";
import { addListItem, setListItemActive, startLists, type ListResult } from "./actions";

type Item = { id: string; kind: "category" | "department"; name: string; is_active: boolean };

export function ListsBoard({ items, canManage }: { items: Item[]; canManage: boolean }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<ListResult | null>(null);
  const [names, setNames] = useState<{ category: string; department: string }>({ category: "", department: "" });
  const run = (f: () => Promise<ListResult>, after?: () => void) =>
    start(async () => {
      const r = await f();
      setMsg(r);
      if (r.ok) after?.();
    });
  const card = (kind: "category" | "department", title: string, hint: string) => {
    const rows = items.filter((i) => i.kind === kind);
    return (
      <section className="card p-4">
        <h2 className="text-sm font-bold">{title}</h2>
        <p className="mb-3 mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
          {hint}
        </p>
        {rows.length === 0 ? (
          <p className="mb-3 text-sm" style={{ color: "var(--color-ink-3)" }}>
            No list yet: anyone can type any name.
          </p>
        ) : (
          <ul className="mb-3 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
            {rows.map((r) => (
              <li key={r.id} className="flex items-center justify-between gap-2 py-2" style={{ borderColor: "var(--color-line)" }}>
                <span style={r.is_active ? undefined : { color: "var(--color-ink-3)", textDecoration: "line-through" }}>{r.name}</span>
                {canManage && (
                  <button type="button" className="text-xs font-semibold" style={{ color: "var(--color-brand)" }} disabled={pending} onClick={() => run(() => setListItemActive(r.id, !r.is_active))}>
                    {r.is_active ? "Switch off" : "Switch on"}
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
        {canManage && (
          <div className="flex gap-2">
            <input className="field h-10 flex-1 text-sm" placeholder="Add a name" maxLength={40} value={names[kind]} onChange={(e) => setNames({ ...names, [kind]: e.target.value })} disabled={pending} />
            <button type="button" className="btn btn-primary px-4 text-sm" disabled={pending || !names[kind].trim()} onClick={() => run(() => addListItem(kind, names[kind]), () => setNames({ ...names, [kind]: "" }))}>
              Add
            </button>
          </div>
        )}
      </section>
    );
  };
  return (
    <div className="space-y-4">
      {msg && (
        <p className="rounded-md px-3 py-2 text-sm" role="status" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {msg.ok ? msg.message : msg.error}
        </p>
      )}
      {canManage && items.length === 0 && (
        <button type="button" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} disabled={pending} onClick={() => run(() => startLists())}>
          Start the lists from what is already in use
        </button>
      )}
      {card("category", "Item groups", "Vegetables, Dairy… Once a group is listed here, an item can only be put in a listed group.")}
      {card("department", "Departments", "Kitchen, Bar… Once a department is listed here, stock requests and issues must use a listed department.")}
    </div>
  );
}
