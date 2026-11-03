"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState, useTransition } from "react";
import type { GroupRow } from "@/lib/fo";
import { addDays } from "@/lib/format";
import { createGroup } from "../actions";
import { RoomLines, linesValid, newLine, toLines, type LineState, type PlanOpt, type TypeOpt } from "./room-lines";

export function GroupsClient({ groups, types, plans, today, canManage, showPast }: {
  groups: GroupRow[]; types: TypeOpt[]; plans: PlanOpt[]; today: string; canManage: boolean; showPast: boolean;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [pending, start] = useTransition();
  const [err, setErr] = useState<string | null>(null);
  const [name, setName] = useState("");
  const [contact, setContact] = useState("");
  const [phone, setPhone] = useState("");
  const [arrival, setArrival] = useState(today);
  const [departure, setDeparture] = useState(addDays(today, 2));
  const [notes, setNotes] = useState("");
  const [lines, setLines] = useState<LineState[]>([newLine(types)]);
  const ref = useRef(crypto.randomUUID());
  const ready = name.trim() && contact.trim() && departure > arrival && linesValid(lines);

  function save() {
    setErr(null);
    start(async () => {
      const r = await createGroup({ name, contactName: contact, contactPhone: phone, arrival, departure, notes, rooms: toLines(lines), clientRef: ref.current });
      if (r.ok) router.push(`/front-office/groups/${r.groupId}`);
      else setErr(r.error);
    });
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-extrabold">Groups</h1>
        <div className="flex items-center gap-3 text-sm">
          <Link href={showPast ? "/front-office/groups" : "/front-office/groups?past=1"} className="underline">{showPast ? "Hide past and cancelled" : "Show past and cancelled"}</Link>
          <Link href="/front-office" className="underline">Back to front office</Link>
          {canManage && types.length > 0 && <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" onClick={() => setOpen(!open)}>{open ? "Close" : "New group"}</button>}
        </div>
      </div>

      {open && canManage && (
        <section className="card space-y-3 p-4">
          <h2 className="text-sm font-bold">New group booking</h2>
          {err && <div role="alert" className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{err}</div>}
          <div className="grid gap-2 sm:grid-cols-2">
            <label className="text-xs sm:col-span-2">Group name<input className="field h-10 w-full text-sm" placeholder="Sharma wedding" value={name} onChange={(e) => setName(e.target.value)} /></label>
            <label className="text-xs">Contact person<input className="field h-10 w-full text-sm" value={contact} onChange={(e) => setContact(e.target.value)} /></label>
            <label className="text-xs">Contact phone<input className="field h-10 w-full text-sm" inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} /></label>
            <label className="text-xs">Arrival<input type="date" className="field h-10 w-full text-sm" min={today} value={arrival} onChange={(e) => setArrival(e.target.value)} /></label>
            <label className="text-xs">Departure<input type="date" className="field h-10 w-full text-sm" min={arrival} value={departure} onChange={(e) => setDeparture(e.target.value)} /></label>
            <label className="text-xs sm:col-span-2">Notes<input className="field h-10 w-full text-sm" value={notes} onChange={(e) => setNotes(e.target.value)} /></label>
          </div>
          <RoomLines lines={lines} setLines={setLines} types={types} plans={plans} />
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>All rooms are booked together. If one room type runs out, nothing is booked. You can put each guest&apos;s name on a room afterwards.</p>
          <button className="btn btn-primary h-10 min-h-0 px-4 text-sm" disabled={pending || !ready} onClick={save}>Book the group</button>
        </section>
      )}

      <section className="card p-4">
        {groups.length === 0 ? (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No {showPast ? "" : "upcoming "}groups yet.{types.length === 0 ? " Add room types first under Rooms and rates." : ""}</p>
        ) : (
          <ul className="divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
            {groups.map((g) => (
              <li key={g.group_id} className="py-2" style={g.status === "cancelled" ? { opacity: 0.55 } : undefined}>
                <Link href={`/front-office/groups/${g.group_id}`} className="flex flex-wrap items-center justify-between gap-2">
                  <span><b>#{g.group_no} · {g.name}</b><span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>{g.contact_name} · {g.arrival} to {g.departure}</span></span>
                  <span className="text-xs">{g.status === "cancelled" ? "Cancelled" : `${g.rooms} room${g.rooms === 1 ? "" : "s"}${g.in_house ? ` · ${g.in_house} in-house` : ""}`}</span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
