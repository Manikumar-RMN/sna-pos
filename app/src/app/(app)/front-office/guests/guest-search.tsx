"use client";

import { useState, useTransition } from "react";
import type { GuestRow } from "@/lib/fo";
import { findGuests, setGuestFlags } from "../actions";

export function GuestSearch({ canManage }: { canManage: boolean }) {
  const [q, setQ] = useState("");
  const [rows, setRows] = useState<GuestRow[] | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function search() {
    setMsg(null);
    start(async () => {
      const r = await findGuests(q);
      if (r.ok) setRows(r.guests); else setMsg(r.error);
    });
  }
  function flag(g: GuestRow, patch: Parameters<typeof setGuestFlags>[1]) {
    setMsg(null);
    start(async () => {
      const r = await setGuestFlags(g.guest_id, patch);
      if (!r.ok) { setMsg(r.error); return; }
      const f = await findGuests(q);
      if (f.ok) setRows(f.guests);
    });
  }
  const ask = (t: string) => { const v = window.prompt(t); return v && v.trim() ? v.trim() : null; };

  return (
    <div className="space-y-3">
      <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); search(); }}>
        <input className="field h-11 flex-1 text-sm" placeholder="Name, phone or email (2 letters or more)" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Search guests" />
        <button className="btn btn-primary h-11 min-h-0 px-5 text-sm" disabled={pending || q.trim().length < 2}>Search</button>
      </form>
      {msg && <div role="alert" className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg}</div>}
      {rows && rows.length === 0 && <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No guest found.</p>}
      <ul className="space-y-2">
        {rows?.map((g) => (
          <li key={g.guest_id} className="card p-3 text-sm">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <b>{g.full_name}{g.vip ? " ★" : ""}</b>
              <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>{g.stays} stay{g.stays === 1 ? "" : "s"}{g.last_stay ? ` · last ${g.last_stay}` : ""}</span>
            </div>
            <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>{[g.phone, g.email, g.city].filter(Boolean).join(" · ")}</p>
            {g.preferences && <p className="mt-1 text-xs">Likes: {g.preferences}</p>}
            {g.blocked && <p className="mt-1 text-xs font-bold" style={{ color: "var(--color-bad)" }}>Blocked: {g.blocked_reason}</p>}
            {canManage && (
              <div className="mt-2 flex flex-wrap gap-2">
                <button className="btn h-9 min-h-0 px-3 text-xs" style={{ border: "1px solid var(--color-line)" }} disabled={pending} onClick={() => flag(g, { vip: !g.vip })}>{g.vip ? "Remove VIP" : "Mark VIP"}</button>
                <button className="btn h-9 min-h-0 px-3 text-xs" style={{ border: "1px solid var(--color-line)" }} disabled={pending} onClick={() => { const v = ask("Preferences (for example: high floor, no feather pillows)"); if (v) flag(g, { preferences: v }); }}>Edit preferences</button>
                {g.blocked
                  ? <button className="btn h-9 min-h-0 px-3 text-xs" style={{ border: "1px solid var(--color-line)" }} disabled={pending} onClick={() => flag(g, { blocked: false })}>Unblock</button>
                  : <button className="btn h-9 min-h-0 px-3 text-xs" style={{ border: "1px solid var(--color-line)" }} disabled={pending} onClick={() => { const v = ask("Why is this guest being blocked?"); if (v) flag(g, { blocked: true, blockedReason: v }); }}>Block</button>}
              </div>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
