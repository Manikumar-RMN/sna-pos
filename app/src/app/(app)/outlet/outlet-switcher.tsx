"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { switchOutlet } from "./actions";

export type OutletInfo = {
  current: string;
  all_outlets: boolean;
  can_all: boolean;
  fixed: boolean;
  outlets: { id: string; name: string; code: string; city: string | null; central_kitchen: boolean }[];
};

/** Outlet picker in the header. A counter tablet always stays in its own outlet. */
export function OutletSwitcher({ info, onGreen }: { info: OutletInfo; onGreen: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  if (info.outlets.length < 2) return null;
  const current = info.outlets.find((o) => o.id === info.current);
  if (info.fixed) {
    return (
      <span className="text-xs font-bold" style={{ color: onGreen ? "#fff" : "var(--color-ink-2)" }}>
        {current?.name}
      </span>
    );
  }
  const value = info.all_outlets ? `all:${info.current}` : info.current;
  return (
    <label className="flex items-center gap-1.5 text-xs font-bold" style={{ color: onGreen ? "#fff" : "var(--color-ink-2)" }}>
      <span className="hidden sm:inline">Outlet</span>
      <select
        className="h-9 rounded-xl border px-2 text-xs font-bold"
        style={{ borderColor: "var(--color-line)", background: "var(--color-surface)", color: "var(--color-ink)" }}
        value={value}
        disabled={pending}
        onChange={(e) => {
          const v = e.target.value;
          const all = v.startsWith("all:");
          const id = all ? v.slice(4) : v;
          start(async () => {
            const r = await switchOutlet(id, all);
            setErr(r.ok ? null : r.error);
            router.refresh();
          });
        }}
      >
        {info.outlets.map((o) => (
          <option key={o.id} value={o.id}>
            {o.name}
            {o.central_kitchen ? " (central kitchen)" : ""}
          </option>
        ))}
        {info.can_all && <option value={`all:${info.current}`}>All outlets (reports) — working in {current?.name}</option>}
      </select>
      {err && <span style={{ color: "var(--color-bad)" }}>{err}</span>}
    </label>
  );
}
