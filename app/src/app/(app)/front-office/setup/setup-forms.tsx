"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { saveRoom, saveRoomType, saveTaxSettings } from "../actions";

type RT = { id: string; code: string; name: string; base_rate: number; max_occupancy: number; active: boolean };
type RM = { id: string; room_number: string; room_type_id: string; floor: string | null; active: boolean };
type Settings = { room_tax_pct: number; room_tax_pct_high: number; room_tax_threshold: number; other_tax_pct: number };
export type SetupData = { room_types: RT[]; rooms: RM[]; settings: Settings };

export function SetupForms({ data, currency }: { data: SetupData; currency: string }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const [tCode, setTCode] = useState("");
  const [tName, setTName] = useState("");
  const [tRate, setTRate] = useState("");
  const [tOcc, setTOcc] = useState("2");
  const [rNo, setRNo] = useState("");
  const [rType, setRType] = useState(data.room_types[0]?.id ?? "");
  const [rFloor, setRFloor] = useState("");
  const [tax, setTax] = useState({
    roomTax: String(data.settings.room_tax_pct), roomTaxHigh: String(data.settings.room_tax_pct_high),
    threshold: String(data.settings.room_tax_threshold), otherTax: String(data.settings.other_tax_pct),
  });

  function act(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error ?? "That did not work." });
      if (r.ok) { after?.(); router.refresh(); }
    });
  }
  const typeName = (id: string) => data.room_types.find((t) => t.id === id)?.name ?? "";

  return (
    <div className="space-y-4">
      {msg && (
        <div role="status" className="rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>
          {msg.text}
        </div>
      )}

      <section className="card p-4">
        <h2 className="text-sm font-bold">Room types</h2>
        <ul className="mt-2 divide-y text-sm">
          {data.room_types.length === 0 && <li className="py-2" style={{ color: "var(--color-ink-3)" }}>No room types yet. Add one below, for example Standard or Suite.</li>}
          {data.room_types.map((t) => (
            <li key={t.id} className="flex items-center justify-between gap-2 py-2" style={t.active ? undefined : { opacity: 0.5 }}>
              <span><b>{t.code}</b> · {t.name} · up to {t.max_occupancy} · {t.base_rate} {currency}/night</span>
              <button className="text-xs underline" disabled={pending} onClick={() => act(() => saveRoomType({ id: t.id, code: t.code, name: t.name, baseRate: t.base_rate, maxOccupancy: t.max_occupancy, active: !t.active }))}>
                {t.active ? "Switch off" : "Switch on"}
              </button>
            </li>
          ))}
        </ul>
        <div className="mt-3 grid gap-2 sm:grid-cols-[80px_1fr_110px_80px_auto]">
          <input className="field h-10 text-sm" placeholder="Code" value={tCode} onChange={(e) => setTCode(e.target.value)} aria-label="Code" />
          <input className="field h-10 text-sm" placeholder="Name (Standard Room)" value={tName} onChange={(e) => setTName(e.target.value)} aria-label="Name" />
          <input className="field h-10 text-sm" inputMode="decimal" placeholder="Rate / night" value={tRate} onChange={(e) => setTRate(e.target.value)} aria-label="Rate per night" />
          <input className="field h-10 text-sm" inputMode="numeric" placeholder="Max" value={tOcc} onChange={(e) => setTOcc(e.target.value)} aria-label="Maximum guests" />
          <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending || !tCode.trim() || !tName.trim() || !(Number(tRate) >= 0) || tRate.trim() === ""}
            onClick={() => act(() => saveRoomType({ id: null, code: tCode, name: tName, baseRate: Number(tRate), maxOccupancy: Number(tOcc) || 2, active: true }), () => { setTCode(""); setTName(""); setTRate(""); })}>Add</button>
        </div>
      </section>

      <section className="card p-4">
        <h2 className="text-sm font-bold">Rooms in this property</h2>
        <ul className="mt-2 grid gap-1 text-sm sm:grid-cols-2">
          {data.rooms.length === 0 && <li style={{ color: "var(--color-ink-3)" }}>No rooms yet.</li>}
          {data.rooms.map((r) => (
            <li key={r.id} className="flex items-center justify-between rounded-lg px-2 py-1" style={{ background: "var(--color-surface-2)", opacity: r.active ? 1 : 0.5 }}>
              <span><b>{r.room_number}</b> · {typeName(r.room_type_id)}{r.floor ? ` · ${r.floor}` : ""}</span>
              <button className="text-xs underline" disabled={pending} onClick={() => act(() => saveRoom({ id: r.id, roomNumber: r.room_number, roomTypeId: r.room_type_id, floor: r.floor ?? "", active: !r.active }))}>
                {r.active ? "Retire" : "Restore"}
              </button>
            </li>
          ))}
        </ul>
        <div className="mt-3 grid gap-2 sm:grid-cols-[100px_1fr_1fr_auto]">
          <input className="field h-10 text-sm" placeholder="Room no." value={rNo} onChange={(e) => setRNo(e.target.value)} aria-label="Room number" />
          <select className="field h-10 text-sm" value={rType} onChange={(e) => setRType(e.target.value)} aria-label="Room type">
            {data.room_types.filter((t) => t.active).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
          </select>
          <input className="field h-10 text-sm" placeholder="Floor (optional)" value={rFloor} onChange={(e) => setRFloor(e.target.value)} aria-label="Floor" />
          <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending || !rNo.trim() || !rType}
            onClick={() => act(() => saveRoom({ id: null, roomNumber: rNo, roomTypeId: rType, floor: rFloor, active: true }), () => { setRNo(""); })}>Add</button>
        </div>
      </section>

      <section className="card p-4">
        <h2 className="text-sm font-bold">Tax on room charges</h2>
        <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Rooms priced up to the limit use the lower rate; dearer rooms use the higher one. Check these with your tax adviser before you rely on them.
        </p>
        <div className="mt-2 grid gap-2 sm:grid-cols-4">
          <label className="text-xs">Lower rate %<input className="field h-10 w-full text-sm" inputMode="decimal" value={tax.roomTax} onChange={(e) => setTax({ ...tax, roomTax: e.target.value })} /></label>
          <label className="text-xs">Higher rate %<input className="field h-10 w-full text-sm" inputMode="decimal" value={tax.roomTaxHigh} onChange={(e) => setTax({ ...tax, roomTaxHigh: e.target.value })} /></label>
          <label className="text-xs">Limit ({currency}/night)<input className="field h-10 w-full text-sm" inputMode="decimal" value={tax.threshold} onChange={(e) => setTax({ ...tax, threshold: e.target.value })} /></label>
          <label className="text-xs">Other charges %<input className="field h-10 w-full text-sm" inputMode="decimal" value={tax.otherTax} onChange={(e) => setTax({ ...tax, otherTax: e.target.value })} /></label>
        </div>
        <button className="btn btn-primary mt-3 h-10 min-h-0 px-4 text-sm" disabled={pending}
          onClick={() => act(() => saveTaxSettings({ roomTax: Number(tax.roomTax), roomTaxHigh: Number(tax.roomTaxHigh), threshold: Number(tax.threshold), otherTax: Number(tax.otherTax) }))}>Save tax settings</button>
      </section>
    </div>
  );
}
