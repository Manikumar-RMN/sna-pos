"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { HK_TASK_LABEL, type HkRow, type HkTask } from "@/lib/fo";
import { assignRooms, setRoomStatus } from "../actions";

const ORDER: HkTask[] = ["departure", "vacant_dirty", "stayover", "to_inspect", "ready", "out_of_service"];

export function HousekeepingBoard({ rows, staff, canAssign }: { rows: HkRow[]; staff: { id: string; full_name: string }[]; canAssign: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  const [picked, setPicked] = useState<string[]>([]);
  const [who, setWho] = useState("");
  const [filter, setFilter] = useState<HkTask | "all">("all");

  const counts = ORDER.map((t) => [t, rows.filter((r) => r.task === t).length] as const);
  const shown = rows.filter((r) => filter === "all" || r.task === filter);

  function run(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? null : (r.error ?? "That did not work."));
      if (r.ok) { setPicked([]); router.refresh(); }
    });
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap gap-1.5" role="tablist">
        <button className="rounded-full px-3 py-1.5 text-xs font-bold" onClick={() => setFilter("all")} style={filter === "all" ? { background: "var(--color-brand)", color: "#fff" } : { border: "1px solid var(--color-line)" }}>All {rows.length}</button>
        {counts.filter(([, n]) => n > 0).map(([t, n]) => (
          <button key={t} className="rounded-full px-3 py-1.5 text-xs font-bold" onClick={() => setFilter(t)} style={filter === t ? { background: "var(--color-brand)", color: "#fff" } : { border: "1px solid var(--color-line)" }}>
            {HK_TASK_LABEL[t]} {n}
          </button>
        ))}
      </div>

      {msg && <div role="alert" className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg}</div>}

      {canAssign && picked.length > 0 && (
        <div className="card flex flex-wrap items-center gap-2 p-3 text-sm">
          <b>{picked.length} room{picked.length === 1 ? "" : "s"} selected</b>
          <select className="field h-10 text-sm" value={who} onChange={(e) => setWho(e.target.value)} aria-label="Attendant">
            <option value="">Nobody (clear)</option>
            {staff.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </select>
          <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending} onClick={() => run(() => assignRooms(picked, who || null, ""))}>Assign</button>
        </div>
      )}

      <ul className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {shown.sort((a, b) => ORDER.indexOf(a.task) - ORDER.indexOf(b.task) || a.room_number.localeCompare(b.room_number, undefined, { numeric: true })).map((r) => (
          <li key={r.room_id} className="card p-3 text-sm">
            <div className="flex items-start justify-between gap-2">
              <label className="flex items-center gap-2 font-bold">
                {canAssign && <input type="checkbox" checked={picked.includes(r.room_id)} onChange={(e) => setPicked(e.target.checked ? [...picked, r.room_id] : picked.filter((x) => x !== r.room_id))} aria-label={`Select room ${r.room_number}`} />}
                Room {r.room_number}
                {r.vip && <span className="rounded-full px-2 py-0.5 text-[10px]" style={{ background: "var(--color-accent)", color: "#1B1208" }}>VIP</span>}
              </label>
              <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>{r.room_type}</span>
            </div>
            <p className="mt-1 text-xs font-semibold">{HK_TASK_LABEL[r.task]}{r.arriving_today ? " · arrival today" : ""}</p>
            {r.guest_name && <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>{r.guest_name}{r.departure ? ` · leaves ${r.departure}` : ""}</p>}
            {r.oos_reason && <p className="text-xs" style={{ color: "var(--color-bad)" }}>{r.oos_reason}</p>}
            <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>{r.attendant ? `Attendant: ${r.attendant}` : "No attendant"}{r.note ? ` · ${r.note}` : ""}</p>
            {!r.out_of_service && !r.occupied && (
              <div className="mt-2 flex flex-wrap gap-2">
                {r.housekeeping === "dirty" && <button className="btn h-9 min-h-0 px-3 text-xs" style={{ border: "1px solid var(--color-line)" }} disabled={pending} onClick={() => run(() => setRoomStatus(r.room_id, { housekeeping: "clean" }))}>Mark clean</button>}
                {r.housekeeping === "clean" && !r.inspected && <button className="btn btn-pay h-9 min-h-0 px-3 text-xs" disabled={pending} onClick={() => run(() => setRoomStatus(r.room_id, { housekeeping: "inspected" }))}>Inspected</button>}
                {r.housekeeping === "clean" && <button className="btn h-9 min-h-0 px-3 text-xs" style={{ border: "1px solid var(--color-line)" }} disabled={pending} onClick={() => run(() => setRoomStatus(r.room_id, { housekeeping: "dirty" }))}>Mark dirty</button>}
              </div>
            )}
          </li>
        ))}
      </ul>
    </div>
  );
}
