"use client";

import type { GroupRoomLine } from "../actions";

export type TypeOpt = { id: string; name: string; max_occupancy: number };
export type PlanOpt = { id: string; code: string; name: string };
export type LineState = { roomTypeId: string; qty: string; adults: string; children: string; ratePlanId: string; rate: string };

export const newLine = (types: TypeOpt[]): LineState => ({ roomTypeId: types[0]?.id ?? "", qty: "1", adults: "2", children: "0", ratePlanId: "", rate: "" });

export function toLines(lines: LineState[]): GroupRoomLine[] {
  return lines.map((l) => ({
    roomTypeId: l.roomTypeId, qty: Number(l.qty) || 1, adults: Number(l.adults) || 1, children: Number(l.children) || 0,
    ratePlanId: l.ratePlanId || null, rate: l.rate.trim() === "" ? null : Number(l.rate),
  }));
}
export const linesValid = (lines: LineState[]) =>
  lines.length > 0 && lines.every((l) => l.roomTypeId && Number(l.qty) >= 1 && Number(l.qty) <= 50 && Number(l.adults) >= 1 && (l.rate.trim() === "" || Number(l.rate) >= 0));

/** The room lines of a group: room type, how many, guests per room, price list, optional agreed rate. */
export function RoomLines({ lines, setLines, types, plans }: { lines: LineState[]; setLines: (l: LineState[]) => void; types: TypeOpt[]; plans: PlanOpt[] }) {
  const upd = (i: number, k: keyof LineState, v: string) => setLines(lines.map((l, j) => (j === i ? { ...l, [k]: v } : l)));
  return (
    <div className="space-y-2">
      {lines.map((l, i) => (
        <div key={i} className="grid gap-2 rounded-xl p-2 sm:grid-cols-[2fr_70px_70px_70px_2fr_1fr_auto]" style={{ border: "1px solid var(--color-line)" }}>
          <label className="text-xs">Room type
            <select className="field h-10 w-full text-sm" value={l.roomTypeId} onChange={(e) => upd(i, "roomTypeId", e.target.value)}>
              {types.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          </label>
          <label className="text-xs">Rooms<input className="field h-10 w-full text-sm" inputMode="numeric" value={l.qty} onChange={(e) => upd(i, "qty", e.target.value)} /></label>
          <label className="text-xs">Adults<input className="field h-10 w-full text-sm" inputMode="numeric" value={l.adults} onChange={(e) => upd(i, "adults", e.target.value)} /></label>
          <label className="text-xs">Kids<input className="field h-10 w-full text-sm" inputMode="numeric" value={l.children} onChange={(e) => upd(i, "children", e.target.value)} /></label>
          <label className="text-xs">Price list
            <select className="field h-10 w-full text-sm" value={l.ratePlanId} onChange={(e) => upd(i, "ratePlanId", e.target.value)}>
              <option value="">Standard room rate</option>
              {plans.map((p) => <option key={p.id} value={p.id}>{p.code} · {p.name}</option>)}
            </select>
          </label>
          <label className="text-xs">Agreed rate<input className="field h-10 w-full text-sm" inputMode="decimal" placeholder="optional" value={l.rate} onChange={(e) => upd(i, "rate", e.target.value)} /></label>
          <div className="flex items-end">
            {lines.length > 1 && <button className="h-10 px-2 text-xs underline" onClick={() => setLines(lines.filter((_, j) => j !== i))}>Remove</button>}
          </div>
        </div>
      ))}
      <button className="text-sm underline" onClick={() => setLines([...lines, newLine(types)])}>Add another room type</button>
      <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>An agreed rate is the price per room per night before tax. Leave it empty to use the price list.</p>
    </div>
  );
}
