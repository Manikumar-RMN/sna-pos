"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { STATUS_LABEL, type Company, type GroupView } from "@/lib/fo";
import { addGroupRooms, cancelGroup, setGroupCompany, setStayGuest } from "../../actions";
import { RoomLines, linesValid, newLine, toLines, type LineState, type PlanOpt, type TypeOpt } from "../room-lines";

export function GroupDetail({ data, types, plans, currency, canManage, companies }: { data: GroupView; types: TypeOpt[]; plans: PlanOpt[]; currency: string; canManage: boolean; companies: Company[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [adding, setAdding] = useState(false);
  const [lines, setLines] = useState<LineState[]>([newLine(types)]);
  const [naming, setNaming] = useState<string | null>(null);
  const [gName, setGName] = useState("");
  const [gPhone, setGPhone] = useState("");
  const [coId, setCoId] = useState("");
  const [coScope, setCoScope] = useState<"room" | "all">("room");
  const { group, stays, totals } = data;
  const live = group.status === "active";

  function act(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>, after?: () => void) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Done." } : { ok: false, text: r.error ?? "That did not work." });
      if (r.ok) { after?.(); router.refresh(); }
    });
  }

  return (
    <div className="space-y-4">
      <Link href="/front-office/groups" className="text-sm underline">← Groups</Link>
      <header className="card p-4">
        <div className="flex flex-wrap items-start justify-between gap-2">
          <div>
            <h1 className="text-xl font-extrabold">#{group.group_no} · {group.name}</h1>
            <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              {group.contact_name} · {group.arrival} to {group.departure} ({group.nights} night{group.nights === 1 ? "" : "s"})
            </p>
            {group.notes && <p className="text-sm">{group.notes}</p>}
            {group.cancel_reason && <p className="text-sm">Cancelled: {group.cancel_reason}</p>}
          </div>
          <span className="rounded-full px-3 py-1 text-xs font-bold" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)" }}>{live ? "Active" : "Cancelled"}</span>
        </div>
        <p className="mt-2 text-sm">
          {totals.rooms} room{totals.rooms === 1 ? "" : "s"} · Guests charged {money(totals.charged, currency)}{totals.company_part > 0 ? ` · Companies pay ${money(totals.company_part, currency)}` : ""} · Paid {money(totals.paid, currency)} · <b style={{ color: totals.balance > 0 ? "var(--color-bad)" : "var(--color-ok)" }}>{totals.balance > 0 ? `Owes ${money(totals.balance, currency)}` : totals.balance < 0 ? `In credit ${money(-totals.balance, currency)}` : "Settled"}</b>
        </p>
      </header>

      {msg && <div role="status" className="rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{msg.text}</div>}

      <section className="card p-4">
        <h2 className="text-sm font-bold">Rooms</h2>
        <ul className="mt-2 divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
          {stays.map((s) => (
            <li key={s.stay_id} className="py-2" style={s.status === "cancelled" ? { opacity: 0.5 } : undefined}>
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span>
                  <Link href={`/front-office/stay/${s.stay_id}`} className="font-semibold underline">#{s.stay_no} · {s.guest_name}</Link>
                  <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
                    {s.room_type}{s.room_number ? ` · Room ${s.room_number}` : ""} · {money(s.rate, currency)}/night · {s.adults} adult{s.adults === 1 ? "" : "s"}{s.children ? `, ${s.children} child${s.children === 1 ? "" : "ren"}` : ""} · {STATUS_LABEL[s.status]}{s.company ? ` · ${s.company} pays ${s.company_scope === "all" ? "everything" : "the room"}` : ""}
                  </span>
                </span>
                <span className="flex items-center gap-3">
                  {s.status !== "cancelled" && <b style={{ color: s.balance > 0 ? "var(--color-bad)" : undefined }}>{money(s.balance, currency)}</b>}
                  {canManage && s.status === "reserved" && (
                    <button className="text-xs underline" onClick={() => { setNaming(naming === s.stay_id ? null : s.stay_id); setGName(""); setGPhone(""); }}>Name the guest</button>
                  )}
                </span>
              </div>
              {naming === s.stay_id && (
                <div className="mt-2 grid gap-2 sm:grid-cols-[2fr_1.5fr_auto]">
                  <input className="field h-10 text-sm" placeholder="Guest name" value={gName} onChange={(e) => setGName(e.target.value)} aria-label="Guest name" />
                  <input className="field h-10 text-sm" inputMode="tel" placeholder="Phone" value={gPhone} onChange={(e) => setGPhone(e.target.value)} aria-label="Guest phone" />
                  <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending || !gName.trim()}
                    onClick={() => act(() => setStayGuest(group.group_id, s.stay_id, gName.trim(), gPhone.trim()), () => setNaming(null))}>Save</button>
                </div>
              )}
            </li>
          ))}
        </ul>
        <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>Each room has its own folio, check-in, check-out and tax invoice. Open a room to take a payment or check the guest in.</p>
      </section>

      {canManage && live && (
        <section className="card p-4">
          <h2 className="text-sm font-bold">Bill the group to a company</h2>
          <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>Sets the company on every room that has not checked out or been cancelled. A room that already has a tax invoice stops this, and nothing changes.</p>
          <div className="mt-2 grid gap-2 sm:grid-cols-[2fr_1.5fr_auto]">
            <select className="field h-10 text-sm" value={coId} onChange={(e) => setCoId(e.target.value)} aria-label="Company">
              <option value="">No company (guests pay)</option>
              {companies.map((c) => <option key={c.company_id} value={c.company_id}>{c.name}</option>)}
            </select>
            <select className="field h-10 text-sm" value={coScope} onChange={(e) => setCoScope(e.target.value as "room" | "all")} aria-label="What the company pays" disabled={!coId}>
              <option value="room">Company pays the room</option>
              <option value="all">Company pays everything</option>
            </select>
            <button className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }} disabled={pending}
              onClick={() => act(() => setGroupCompany(group.group_id, coId || null, coScope))}>Apply to all rooms</button>
          </div>
          {companies.length === 0 && <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}><Link href="/front-office/companies" className="underline">Add a company</Link> first.</p>}
        </section>
      )}

      {canManage && live && (
        <section className="card space-y-3 p-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 className="text-sm font-bold">Add rooms or cancel</h2>
            <div className="flex gap-2">
              <button className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }} onClick={() => setAdding(!adding)}>{adding ? "Close" : "Add rooms"}</button>
              <button className="btn h-10 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }} disabled={pending}
                onClick={() => { const r = window.prompt("Why is the whole group being cancelled?"); if (r && r.trim()) act(() => cancelGroup(group.group_id, r.trim())); }}>Cancel the group</button>
            </div>
          </div>
          {adding && (
            <>
              <RoomLines lines={lines} setLines={setLines} types={types} plans={plans} />
              <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending || !linesValid(lines)}
                onClick={() => act(() => addGroupRooms(group.group_id, toLines(lines)), () => { setAdding(false); setLines([newLine(types)]); })}>Add to the group</button>
            </>
          )}
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>Cancelling the group cancels every room that has not arrived. If a room has an advance payment, refund it first. If a room has checked in, cancel the other rooms one by one.</p>
        </section>
      )}
    </div>
  );
}
