"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { waNumber } from "../bills/whatsapp-share";
import { saveBooking, setBookingStatus } from "./actions";

type Row = {
  id: string;
  name: string;
  phone: string | null;
  party: number;
  when: string | null;
  status: "booked" | "waiting" | "seated" | "cancelled" | "no_show";
  note: string | null;
  createdAt: string;
  tableId: string | null;
};

export function Bookings({
  rows,
  tables,
  canEdit,
  timezone,
  country,
  restaurant,
}: {
  rows: Row[];
  tables: { id: string; number: string }[];
  canEdit: boolean;
  timezone: string;
  country: string;
  restaurant: string;
  whatsapp?: boolean;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [form, setForm] = useState({ name: "", phone: "", party: "2", date: "", time: "", table: "", note: "" });
  const [seating, setSeating] = useState<Record<string, string>>({});
  const tableNo = (id: string | null) => tables.find((t) => t.id === id)?.number;
  const fmt = (iso: string) =>
    new Date(iso).toLocaleString("en-IN", { timeZone: timezone, weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
  const since = (iso: string) => Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));

  const waiting = rows.filter((r) => r.status === "waiting");
  const booked = rows.filter((r) => r.status === "booked");
  const done = rows.filter((r) => !["waiting", "booked"].includes(r.status));

  function act(fn: () => Promise<{ ok: boolean; error?: string }>) {
    setError(null);
    start(async () => {
      const r = await fn();
      if (!r.ok) setError(r.error ?? "Could not save.");
      else router.refresh();
    });
  }
  function add(waitlist: boolean) {
    let when: string | null = null;
    if (!waitlist) {
      if (!form.date || !form.time) return setError("Choose the date and time.");
      when = new Date(`${form.date}T${form.time}`).toISOString();
    }
    act(async () => {
      const r = await saveBooking({ id: null, name: form.name, phone: form.phone, party: Number(form.party), when, tableId: form.table || null, note: form.note });
      if (r.ok) setForm({ name: "", phone: "", party: "2", date: form.date, time: "", table: "", note: "" });
      return r;
    });
  }
  const notify = (r: Row) =>
    r.phone &&
    window.open(
      `https://wa.me/${waNumber("+" + r.phone, country)}?text=${encodeURIComponent(`Hi ${r.name}, your table at ${restaurant} is ready. Please come to the counter.`)}`,
      "_blank",
      "noopener",
    );

  const Actions = ({ r }: { r: Row }) =>
    canEdit ? (
      <div className="mt-2 flex flex-wrap items-center gap-2">
        <select className="field h-9 min-h-0 w-auto py-0 text-sm" value={seating[r.id] ?? r.tableId ?? ""} onChange={(e) => setSeating({ ...seating, [r.id]: e.target.value })} aria-label="Table">
          <option value="">Table…</option>
          {tables.map((t) => <option key={t.id} value={t.id}>{t.number}</option>)}
        </select>
        <button className="btn btn-pay h-9 min-h-0 px-3 text-sm" disabled={pending} onClick={() => act(() => setBookingStatus(r.id, "seated", seating[r.id] || r.tableId))}>Seat</button>
        {r.phone && <button className="btn h-9 min-h-0 border px-3 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => notify(r)}>WhatsApp: table ready</button>}
        <button className="btn h-9 min-h-0 px-3 text-sm" disabled={pending} onClick={() => act(() => setBookingStatus(r.id, r.status === "waiting" ? "cancelled" : "no_show", null))}>
          {r.status === "waiting" ? "Left" : "No-show"}
        </button>
        {r.status === "booked" && (
          <button className="btn h-9 min-h-0 px-3 text-sm" disabled={pending} onClick={() => act(() => setBookingStatus(r.id, "cancelled", null))}>Cancel</button>
        )}
      </div>
    ) : null;

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <h1 className="text-xl font-bold tracking-tight">Bookings and waiting list</h1>
      {canEdit && (
        <section className="card space-y-2 p-4">
          <h2 className="text-sm font-bold">New booking or walk-in</h2>
          <div className="grid gap-2 sm:grid-cols-3">
            <input className="field" placeholder="Guest name" value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} />
            <input className="field" type="tel" placeholder="Phone" value={form.phone} onChange={(e) => setForm({ ...form, phone: e.target.value })} />
            <input className="field" inputMode="numeric" placeholder="People" value={form.party} onChange={(e) => setForm({ ...form, party: e.target.value })} />
            <input className="field" type="date" value={form.date} onChange={(e) => setForm({ ...form, date: e.target.value })} aria-label="Date" />
            <input className="field" type="time" value={form.time} onChange={(e) => setForm({ ...form, time: e.target.value })} aria-label="Time" />
            <select className="field" value={form.table} onChange={(e) => setForm({ ...form, table: e.target.value })} aria-label="Table">
              <option value="">Any table</option>
              {tables.map((t) => <option key={t.id} value={t.id}>Table {t.number}</option>)}
            </select>
          </div>
          <input className="field" placeholder="Note (birthday, high chair…)" value={form.note} onChange={(e) => setForm({ ...form, note: e.target.value })} />
          <div className="flex flex-wrap gap-2">
            <button className="btn btn-primary" disabled={pending} onClick={() => add(false)}>Save booking</button>
            <button className="btn border" style={{ borderColor: "var(--color-line)" }} disabled={pending} onClick={() => add(true)}>Add to waiting list now</button>
          </div>
        </section>
      )}
      {error && <p role="alert" className="text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{error}</p>}

      <section className="card p-4">
        <h2 className="mb-2 text-sm font-bold">Waiting now ({waiting.length})</h2>
        {waiting.length === 0 && <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>Nobody waiting.</p>}
        <ol className="space-y-3">
          {waiting.map((r, i) => (
            <li key={r.id} className="border-b pb-3" style={{ borderColor: "var(--color-line)" }}>
              <div className="text-sm"><b>{i + 1}. {r.name}</b> · {r.party} people · waiting {since(r.createdAt)} min{r.note ? ` · ${r.note}` : ""}</div>
              <Actions r={r} />
            </li>
          ))}
        </ol>
      </section>

      <section className="card p-4">
        <h2 className="mb-2 text-sm font-bold">Upcoming bookings ({booked.length})</h2>
        {booked.length === 0 && <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>No bookings.</p>}
        <ul className="space-y-3">
          {booked.map((r) => (
            <li key={r.id} className="border-b pb-3" style={{ borderColor: "var(--color-line)" }}>
              <div className="text-sm">
                <b>{r.when ? fmt(r.when) : ""}</b> · {r.name} · {r.party} people{tableNo(r.tableId) ? ` · table ${tableNo(r.tableId)}` : ""}
                {r.phone ? ` · +${r.phone}` : ""}{r.note ? ` · ${r.note}` : ""}
              </div>
              <Actions r={r} />
            </li>
          ))}
        </ul>
      </section>

      {done.length > 0 && (
        <details className="card p-4">
          <summary className="cursor-pointer text-sm font-bold">Seated, cancelled and no-shows ({done.length})</summary>
          <ul className="mt-2 space-y-1 text-sm">
            {done.map((r) => (
              <li key={r.id}>{r.name} · {r.party} · {r.status.replace("_", "-")}{tableNo(r.tableId) ? ` · table ${tableNo(r.tableId)}` : ""}</li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
}
