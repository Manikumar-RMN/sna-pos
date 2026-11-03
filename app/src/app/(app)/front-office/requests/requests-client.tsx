"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { REQUEST_KIND_LABEL, type FoRequest, type RequestKind, type RequestList } from "@/lib/fo";
import { addRequest, closeRequest } from "../actions";

const TABS: { key: "open" | "today" | "recent"; label: string }[] = [
  { key: "open", label: "All open" },
  { key: "today", label: "Due today" },
  { key: "recent", label: "Recent" },
];

export function RequestsClient({ list, scope, stays, canWrite }: {
  list: RequestList; scope: string; stays: { id: string; label: string; inhouse: boolean }[]; canWrite: boolean;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [stay, setStay] = useState("");
  const [kind, setKind] = useState<RequestKind>("request");
  const [text, setText] = useState("");
  const [date, setDate] = useState(list.today);
  const [time, setTime] = useState("06:30");
  const [cancelling, setCancelling] = useState<string | null>(null);
  const [why, setWhy] = useState("");

  const chosen = stays.find((s) => s.id === stay);
  const wake = kind === "wakeup";
  const canAdd = !!stay && text.trim() !== "" && (!wake || (!!date && !!time && !!chosen?.inhouse));

  function add() {
    setMsg(null);
    start(async () => {
      const r = await addRequest(stay, kind, text.trim(), wake ? date : undefined, wake ? time : undefined);
      if (r.ok) { setMsg({ ok: true, text: r.message ?? "Saved." }); setText(""); router.refresh(); }
      else setMsg({ ok: false, text: r.error });
    });
  }
  function close(r: FoRequest, status: "done" | "cancelled", note?: string) {
    setMsg(null);
    start(async () => {
      const res = await closeRequest(r.id, status, note);
      if (res.ok) { setMsg({ ok: true, text: res.message ?? "Done." }); setCancelling(null); setWhy(""); router.refresh(); }
      else setMsg({ ok: false, text: res.error });
    });
  }

  return (
    <div className="mt-2 space-y-4">
      <h1 className="text-xl font-extrabold">Requests, messages and wake-up calls</h1>
      {msg && <div role="status" className="rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg.text}</div>}

      {canWrite && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Add</h2>
          <div className="mt-2 grid gap-2 sm:grid-cols-2">
            <label className="text-xs sm:col-span-2">Guest
              <select className="field h-10 w-full text-sm" value={stay} onChange={(e) => setStay(e.target.value)}>
                <option value="">Choose a guest</option>
                {stays.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
              </select>
            </label>
            <label className="text-xs">Type
              <select className="field h-10 w-full text-sm" value={kind} onChange={(e) => setKind(e.target.value as RequestKind)}>
                {(Object.keys(REQUEST_KIND_LABEL) as RequestKind[]).map((k) => <option key={k} value={k}>{REQUEST_KIND_LABEL[k]}</option>)}
              </select>
            </label>
            {wake && (
              <div className="grid grid-cols-2 gap-2">
                <label className="text-xs">Date<input type="date" className="field h-10 w-full text-sm" min={list.today} value={date} onChange={(e) => setDate(e.target.value)} /></label>
                <label className="text-xs">Time<input type="time" className="field h-10 w-full text-sm" value={time} onChange={(e) => setTime(e.target.value)} /></label>
              </div>
            )}
            <label className="text-xs sm:col-span-2">{wake ? "Note for the desk" : kind === "message" ? "Message" : "What the guest asked for"}
              <input className="field h-10 w-full text-sm" maxLength={500} value={text} onChange={(e) => setText(e.target.value)} />
            </label>
          </div>
          {wake && chosen && !chosen.inhouse && <p className="mt-2 text-xs" style={{ color: "var(--color-bad-strong)" }}>A wake-up call needs a guest who is already checked in.</p>}
          <button className="btn btn-primary mt-3 h-10 min-h-0 px-4 text-sm" disabled={!canAdd || pending} onClick={add}>Save</button>
        </section>
      )}

      <div className="flex gap-2">
        {TABS.map((t) => (
          <Link key={t.key} href={`/front-office/requests?scope=${t.key}`} className="btn h-9 min-h-0 px-3 text-sm"
            style={scope === t.key ? { background: "var(--color-ink)", color: "#fff" } : { border: "1px solid var(--color-line)" }}>{t.label}</Link>
        ))}
      </div>

      <div className="space-y-2">
        {list.rows.length === 0 && <div className="card p-4 text-sm" style={{ color: "var(--color-ink-3)" }}>Nothing here.</div>}
        {list.rows.map((r) => (
          <div key={r.id} className="card p-3 text-sm" style={r.overdue ? { borderColor: "var(--color-bad-strong)" } : undefined}>
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div>
                <span className="font-bold">{REQUEST_KIND_LABEL[r.kind]}</span>
                {r.due_date && <span className="ml-2 font-semibold">{r.due_date}{r.due_time ? ` ${r.due_time.slice(0, 5)}` : ""}</span>}
                {r.overdue && <span className="ml-2 text-xs font-bold" style={{ color: "var(--color-bad-strong)" }}>Overdue</span>}
                {r.due_today && <span className="ml-2 text-xs font-bold" style={{ color: "var(--color-ok)" }}>Today</span>}
                {r.status !== "open" && <span className="ml-2 text-xs" style={{ color: "var(--color-ink-3)" }}>{r.status === "done" ? "Done" : "Cancelled"}</span>}
              </div>
              <Link href={`/front-office/stay/${r.stay_id}`} className="text-xs underline">{r.room ? `Room ${r.room}` : `Stay #${r.stay_no}`} · {r.guest}</Link>
            </div>
            <p className="mt-1">{r.text}</p>
            {r.note && <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>{r.note}</p>}
            {canWrite && r.status === "open" && (
              cancelling === r.id ? (
                <div className="mt-2 flex flex-wrap gap-2">
                  <input className="field h-9 flex-1 text-sm" placeholder="Why is it cancelled?" value={why} onChange={(e) => setWhy(e.target.value)} />
                  <button className="btn h-9 min-h-0 px-3 text-sm" disabled={pending || why.trim() === ""} onClick={() => close(r, "cancelled", why.trim())}>Confirm cancel</button>
                  <button className="btn h-9 min-h-0 px-3 text-sm" onClick={() => { setCancelling(null); setWhy(""); }}>Back</button>
                </div>
              ) : (
                <div className="mt-2 flex gap-2">
                  <button className="btn btn-primary h-9 min-h-0 px-3 text-sm" disabled={pending} onClick={() => close(r, "done")}>Done</button>
                  <button className="btn h-9 min-h-0 px-3 text-sm" style={{ border: "1px solid var(--color-line)" }} onClick={() => { setCancelling(r.id); setWhy(""); }}>Cancel</button>
                </div>
              )
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
