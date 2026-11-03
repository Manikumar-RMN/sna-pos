"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState, useTransition, type ReactNode } from "react";
import { money } from "@/lib/format";
import type { DaySheet, RoomCard, RoomTypeAvail } from "@/lib/fo";
import { bookStay, checkAvailability, checkIn, markNoShow, runNightAudit, setRoomStatus, cancelStay } from "./actions";

type Props = {
  rooms: RoomCard[];
  sheet: DaySheet;
  roomTypes: { id: string; code: string; name: string; base_rate: number; max_occupancy: number }[];
  currency: string;
  canManage: boolean;
  canHousekeep: boolean;
  canAudit: boolean;
};

type Tab = "board" | "arrivals" | "inhouse" | "departures" | "audit";

const tone = (r: RoomCard) =>
  r.out_of_service
    ? { bg: "var(--color-bad-soft)", fg: "var(--color-bad-strong)", label: "Out of service" }
    : r.occupied
      ? { bg: "var(--color-info-soft)", fg: "var(--color-info)", label: "Occupied" }
      : r.housekeeping === "dirty"
        ? { bg: "var(--color-warn-soft)", fg: "var(--color-warn)", label: "Dirty" }
        : { bg: "var(--color-ok-soft)", fg: "var(--color-ok)", label: "Vacant clean" };

export function FrontOfficeBoard(p: Props) {
  const router = useRouter();
  const [tab, setTab] = useState<Tab>("board");
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [booking, setBooking] = useState(false);
  const { sheet } = p;

  const counts = {
    arrivals: sheet.arrivals.length,
    inhouse: sheet.in_house.length,
    departures: sheet.departures.length,
  };

  function act(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Done." } : { ok: false, text: r.error ?? "That did not work." });
      if (r.ok) router.refresh();
    });
  }

  const tabs: { id: Tab; label: string; n?: number }[] = [
    { id: "board", label: "Room board" },
    { id: "arrivals", label: "Arrivals", n: counts.arrivals },
    { id: "inhouse", label: "In-house", n: counts.inhouse },
    { id: "departures", label: "Departures", n: counts.departures },
    ...(p.canAudit ? [{ id: "audit" as Tab, label: "Night audit" }] : []),
  ];

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <div role="tablist" className="flex flex-wrap gap-1">
          {tabs.map((t) => (
            <button
              key={t.id}
              role="tab"
              aria-selected={tab === t.id}
              onClick={() => setTab(t.id)}
              className="btn h-10 min-h-0 px-4 text-sm"
              style={tab === t.id ? { background: "var(--color-brand)", color: "#fff" } : { border: "1px solid var(--color-line)", background: "var(--color-surface)" }}
            >
              {t.label}
              {t.n ? <span className="ml-1.5 rounded-full px-1.5 text-xs" style={{ background: "var(--color-accent)", color: "var(--color-accent-ink)" }}>{t.n}</span> : null}
            </button>
          ))}
        </div>
        {p.canManage && (
          <button className="btn btn-pay ml-auto h-10 min-h-0 px-4 text-sm" onClick={() => setBooking(true)}>
            + New booking
          </button>
        )}
      </div>

      {msg && (
        <div role="status" className="rounded-xl px-3 py-2 text-sm font-semibold" style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>
          {msg.text}
        </div>
      )}

      <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
        Business date <b>{sheet.business_date}</b>
        {sheet.audited ? " · night audit done" : ""}
      </p>

      {tab === "board" && (
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-5">
          {p.rooms.length === 0 && (
            <div className="card col-span-full p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
              No rooms yet. {p.canManage ? <Link className="underline" href="/front-office/setup">Add your room types and rooms</Link> : "Ask a manager to add rooms."}
            </div>
          )}
          {p.rooms.map((r) => {
            const t = tone(r);
            return (
              <div key={r.room_id} className="card p-3" style={{ borderColor: t.fg }}>
                <div className="flex items-center justify-between">
                  <b className="text-lg">{r.room_number}</b>
                  <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={{ background: t.bg, color: t.fg }}>{t.label}</span>
                </div>
                <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>{r.room_type}{r.floor ? ` · ${r.floor}` : ""}</div>
                {r.occupied && r.stay_id ? (
                  <Link href={`/front-office/stay/${r.stay_id}`} className="mt-2 block text-sm font-semibold underline">
                    {r.guest_name}
                    <span className="block text-xs font-normal" style={{ color: "var(--color-ink-3)" }}>leaves {r.departure}</span>
                  </Link>
                ) : r.out_of_service ? (
                  <div className="mt-2 text-xs" style={{ color: "var(--color-bad-strong)" }}>{r.oos_reason}</div>
                ) : null}
                {p.canHousekeep && !r.occupied && !r.out_of_service && (
                  <button
                    disabled={pending}
                    className="btn mt-2 h-9 min-h-0 w-full px-2 text-xs"
                    style={{ border: "1px solid var(--color-line)" }}
                    onClick={() => act(() => setRoomStatus(r.room_id, { housekeeping: r.housekeeping === "clean" ? "dirty" : "clean" }))}
                  >
                    Mark {r.housekeeping === "clean" ? "dirty" : "clean"}
                  </button>
                )}
                {p.canHousekeep && !r.occupied && (
                  <button
                    disabled={pending}
                    className="mt-1 w-full text-xs underline"
                    style={{ color: "var(--color-ink-3)" }}
                    onClick={() => {
                      if (r.out_of_service) return act(() => setRoomStatus(r.room_id, { outOfService: false }));
                      const reason = window.prompt(`Why is room ${r.room_number} out of service?`);
                      if (reason && reason.trim()) act(() => setRoomStatus(r.room_id, { outOfService: true, reason }));
                    }}
                  >
                    {r.out_of_service ? "Put back in service" : "Take out of service"}
                  </button>
                )}
              </div>
            );
          })}
        </div>
      )}

      {tab === "arrivals" && (
        <List empty="No arrivals waiting today.">
          {sheet.arrivals.map((a) => (
            <Row key={a.stay_id} href={`/front-office/stay/${a.stay_id}`} title={`${a.guest_name} · #${a.stay_no}`} sub={`${a.room_type} · ${a.nights} night${a.nights === 1 ? "" : "s"} · ${a.adults + a.children} guest${a.adults + a.children === 1 ? "" : "s"} · ${money(a.rate, p.currency)}/night`}>
              {p.canManage && (
                <>
                  <button disabled={pending} className="btn btn-pay h-9 min-h-0 px-3 text-xs" onClick={() => act(() => checkIn(a.stay_id, null))}>Check in</button>
                  <button disabled={pending} className="btn h-9 min-h-0 px-3 text-xs" style={{ border: "1px solid var(--color-line)" }} onClick={() => act(() => markNoShow(a.stay_id))}>No-show</button>
                  <button
                    disabled={pending}
                    className="btn h-9 min-h-0 px-3 text-xs"
                    style={{ border: "1px solid var(--color-line)" }}
                    onClick={() => {
                      const reason = window.prompt("Reason for cancelling?");
                      if (reason && reason.trim()) act(() => cancelStay(a.stay_id, reason));
                    }}
                  >Cancel</button>
                </>
              )}
            </Row>
          ))}
        </List>
      )}

      {tab === "inhouse" && (
        <List empty="No guests in the house.">
          {sheet.in_house.map((s) => (
            <Row key={s.stay_id} href={`/front-office/stay/${s.stay_id}`} title={`Room ${s.room_number ?? "?"} · ${s.guest_name}`} sub={`#${s.stay_no} · leaves ${s.departure}`}>
              <Balance v={s.balance} currency={p.currency} />
            </Row>
          ))}
        </List>
      )}

      {tab === "departures" && (
        <List empty="No departures today.">
          {sheet.departures.map((s) => (
            <Row key={s.stay_id} href={`/front-office/stay/${s.stay_id}`} title={`Room ${s.room_number ?? "?"} · ${s.guest_name}`} sub={`#${s.stay_no}`}>
              <Balance v={s.balance} currency={p.currency} />
              <span className="text-xs underline">Open folio to check out</span>
            </Row>
          ))}
        </List>
      )}

      {tab === "audit" && p.canAudit && (
        <section className="card space-y-3 p-4">
          <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
            The night audit posts tonight&rsquo;s room charge to every in-house guest, marks arrivals that never came as no-shows, and records the day&rsquo;s occupancy and revenue. It can be run once for each business date.
          </p>
          <button
            className="btn btn-pay h-11 min-h-0 px-5 text-sm"
            disabled={pending || sheet.audited}
            onClick={() => {
              if (window.confirm(`Run the night audit for ${sheet.business_date}?`)) act(() => runNightAudit());
            }}
          >
            {sheet.audited ? "Already audited" : `Run night audit for ${sheet.business_date}`}
          </button>
          {sheet.last_audit && (
            <dl className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-4">
              <Stat k={`Last audit · ${sheet.last_audit.business_date}`} v={`${sheet.last_audit.occupancy_pct}% occupied`} />
              <Stat k="Rooms sold" v={`${sheet.last_audit.rooms_sold} of ${sheet.last_audit.rooms_available}`} />
              <Stat k="Room revenue" v={money(sheet.last_audit.room_revenue, p.currency)} />
              <Stat k="Other revenue" v={money(sheet.last_audit.other_revenue, p.currency)} />
              <Stat k="ADR" v={money(sheet.last_audit.adr, p.currency)} />
              <Stat k="RevPAR" v={money(sheet.last_audit.revpar, p.currency)} />
              <Stat k="Collections" v={money(sheet.last_audit.collections, p.currency)} />
              <Stat k="No-shows" v={String(sheet.last_audit.no_shows)} />
            </dl>
          )}
        </section>
      )}

      {booking && (
        <BookingDialog
          roomTypes={p.roomTypes}
          today={sheet.business_date}
          onClose={() => setBooking(false)}
          onBooked={(t) => {
            setBooking(false);
            setMsg({ ok: true, text: t });
            router.refresh();
          }}
        />
      )}
    </div>
  );
}

function List({ children, empty }: { children: ReactNode; empty: string }) {
  const items = Array.isArray(children) ? children : [children];
  return <div className="space-y-2">{items.filter(Boolean).length ? children : <div className="card p-5 text-sm" style={{ color: "var(--color-ink-3)" }}>{empty}</div>}</div>;
}

function Row({ title, sub, href, children }: { title: string; sub: string; href: string; children?: ReactNode }) {
  return (
    <div className="card flex flex-wrap items-center gap-3 p-3">
      <Link href={href} className="min-w-0 flex-1">
        <div className="font-bold">{title}</div>
        <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>{sub}</div>
      </Link>
      <div className="flex items-center gap-2">{children}</div>
    </div>
  );
}

function Balance({ v, currency }: { v: number; currency: string }) {
  return (
    <b className="text-sm" style={{ color: v > 0 ? "var(--color-bad)" : v < 0 ? "var(--color-warn)" : "var(--color-ok)" }}>
      {v > 0 ? "Owes " : v < 0 ? "Credit " : "Settled "}
      {v !== 0 ? money(Math.abs(v), currency) : ""}
    </b>
  );
}

function Stat({ k, v }: { k: string; v: string }) {
  return (
    <div className="rounded-xl p-2" style={{ background: "var(--color-surface-2)" }}>
      <dt className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>{k}</dt>
      <dd className="font-bold">{v}</dd>
    </div>
  );
}

function addDays(ymd: string, n: number) {
  const d = new Date(`${ymd}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function BookingDialog({ roomTypes, today, onClose, onBooked }: { roomTypes: Props["roomTypes"]; today: string; onClose: () => void; onBooked: (msg: string) => void }) {
  const [pending, start] = useTransition();
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [arrival, setArrival] = useState(today);
  const [departure, setDeparture] = useState(addDays(today, 1));
  const [typeId, setTypeId] = useState(roomTypes[0]?.id ?? "");
  const [rate, setRate] = useState("");
  const [adults, setAdults] = useState(1);
  const [kids, setKids] = useState(0);
  const [source, setSource] = useState("walk_in");
  const [avail, setAvail] = useState<RoomTypeAvail[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const clientRef = useRef(crypto.randomUUID());

  function look() {
    setErr(null);
    start(async () => {
      const r = await checkAvailability(arrival, departure);
      if (r.ok) setAvail(r.types);
      else setErr(r.error);
    });
  }
  function save(checkInNow: boolean) {
    setErr(null);
    start(async () => {
      const r = await bookStay({
        fullName: name, phone, roomTypeId: typeId, arrival, departure,
        rate: rate.trim() === "" ? null : Number(rate), adults, children: kids, source, notes: "",
        clientRef: clientRef.current, checkInNow,
      });
      if (r.ok) onBooked(r.message ?? "Booked.");
      else setErr(r.error);
    });
  }
  const t = roomTypes.find((x) => x.id === typeId);
  const ready = name.trim() && typeId && departure > arrival && (rate.trim() === "" || Number(rate) >= 0);

  return (
    <div className="fixed inset-0 z-50 grid place-items-center p-3" style={{ background: "rgba(0,0,0,0.45)" }} role="dialog" aria-modal="true" aria-label="New booking">
      <div className="card max-h-[92vh] w-full max-w-lg space-y-3 overflow-auto p-4">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-extrabold">New booking</h2>
          <button onClick={onClose} className="text-sm underline" aria-label="Close">Close</button>
        </div>
        <div className="grid gap-2 sm:grid-cols-2">
          <input className="field h-10 text-sm" placeholder="Guest name" value={name} onChange={(e) => setName(e.target.value)} aria-label="Guest name" />
          <input className="field h-10 text-sm" inputMode="tel" placeholder="Phone" value={phone} onChange={(e) => setPhone(e.target.value)} aria-label="Phone" />
          <label className="text-xs">Arrival<input type="date" className="field h-10 w-full text-sm" min={today} value={arrival} onChange={(e) => { setArrival(e.target.value); setAvail(null); }} /></label>
          <label className="text-xs">Departure<input type="date" className="field h-10 w-full text-sm" min={addDays(arrival, 1)} value={departure} onChange={(e) => { setDeparture(e.target.value); setAvail(null); }} /></label>
          <select className="field h-10 text-sm" value={typeId} onChange={(e) => setTypeId(e.target.value)} aria-label="Room type">
            {roomTypes.map((x) => <option key={x.id} value={x.id}>{x.name} · {x.base_rate}</option>)}
          </select>
          <input className="field h-10 text-sm" inputMode="decimal" placeholder={t ? `Rate per night (default ${t.base_rate})` : "Rate per night"} value={rate} onChange={(e) => setRate(e.target.value)} aria-label="Rate per night" />
          <label className="text-xs">Adults<input type="number" min={1} className="field h-10 w-full text-sm" value={adults} onChange={(e) => setAdults(Math.max(1, Number(e.target.value) || 1))} /></label>
          <label className="text-xs">Children<input type="number" min={0} className="field h-10 w-full text-sm" value={kids} onChange={(e) => setKids(Math.max(0, Number(e.target.value) || 0))} /></label>
          <select className="field h-10 text-sm sm:col-span-2" value={source} onChange={(e) => setSource(e.target.value)} aria-label="Booked how">
            <option value="walk_in">Walk-in</option><option value="phone">Phone</option><option value="email">Email</option>
            <option value="ota">Online agent</option><option value="corporate">Company</option><option value="other">Other</option>
          </select>
        </div>
        <button className="text-sm underline" onClick={look} disabled={pending}>Check what is free for these dates</button>
        {avail && (
          <ul className="space-y-1 text-sm">
            {avail.map((a) => <li key={a.room_type_id}>{a.name}: <b>{a.free}</b> free of {a.rooms}</li>)}
          </ul>
        )}
        {err && <div role="alert" className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad-strong)" }}>{err}</div>}
        <div className="flex flex-wrap justify-end gap-2">
          <button className="btn h-11 min-h-0 px-4 text-sm" style={{ border: "1px solid var(--color-line)" }} disabled={pending || !ready} onClick={() => save(false)}>Save reservation</button>
          {arrival === today && <button className="btn btn-pay h-11 min-h-0 px-4 text-sm" disabled={pending || !ready} onClick={() => save(true)}>Save and check in</button>}
        </div>
      </div>
    </div>
  );
}
