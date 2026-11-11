"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { cancelKot } from "./actions";

export type KotRow = { id: string; table: string; kot: string; bill: string; paid: boolean; status: string; at: string };

export function KotCancelList({ rows }: { rows: KotRow[] }) {
  const router = useRouter();
  const [pick, setPick] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [sure, setSure] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const [filter, setFilter] = useState("");
  const shown = rows.filter((r) => !filter || r.table.toLowerCase().includes(filter.toLowerCase()) || r.kot.includes(filter));
  return (
    <div className="card p-3">
      <input className="field mb-2 h-9 w-full text-sm" placeholder="Filter by table or KOT no." value={filter} onChange={(e) => setFilter(e.target.value)} />
      <div className="max-h-[50vh] overflow-y-auto rounded-lg border text-sm" style={{ borderColor: "var(--color-line)" }}>
        <div className="grid grid-cols-[60px_70px_1fr_90px] gap-2 px-2 py-1 text-[11px] font-bold" style={{ background: "var(--color-surface-2)" }}>
          <span>Table</span>
          <span>KOT no</span>
          <span>Bill · time</span>
          <span>Status</span>
        </div>
        {shown.length === 0 && <p className="p-3 text-center text-xs">No kitchen tickets.</p>}
        {shown.map((r) => (
          <button
            key={r.id}
            type="button"
            onClick={() => { setPick(r.id); setSure(false); setMsg(null); }}
            className="grid w-full grid-cols-[60px_70px_1fr_90px] gap-2 px-2 py-1.5 text-left"
            style={{ borderTop: "1px solid var(--color-line)", background: pick === r.id ? "var(--color-brand-soft)" : "transparent" }}
          >
            <span>{r.table}</span>
            <span>{r.kot}</span>
            <span className="truncate">{r.bill} · {r.at}</span>
            <span>{r.paid ? "paid" : r.status}</span>
          </button>
        ))}
      </div>
      <div className="mt-3 flex items-center gap-2">
        <input className="field h-10 flex-1 text-sm" placeholder="Reason" value={reason} maxLength={120} onChange={(e) => { setReason(e.target.value); setSure(false); }} />
        <button
          type="button"
          className="btn btn-primary px-4 text-sm"
          disabled={pending || !pick || reason.trim().length < 3}
          onClick={() => {
            if (!sure) return setSure(true);
            start(async () => {
              const res = await cancelKot(pick!, reason);
              if (!res.ok) { setSure(false); return setMsg(res.error); }
              setMsg("KOT cancelled.");
              setPick(null);
              setReason("");
              setSure(false);
              router.refresh();
            });
          }}
        >
          {pending ? "Cancelling…" : sure ? "Press again to cancel this KOT" : "Cancel KOT"}
        </button>
      </div>
      {msg && <p className="mt-2 text-sm" role="status">{msg}</p>}
    </div>
  );
}
