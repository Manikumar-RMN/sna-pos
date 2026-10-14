"use client";

import { useMemo, useState, useTransition } from "react";
import { setCompanyTimezone } from "../actions";

/** Zones people pick most, first; the full list follows. */
const COMMON = ["Asia/Kolkata", "Asia/Dubai", "Asia/Riyadh", "Asia/Singapore", "Asia/Kuala_Lumpur", "Asia/Manila", "Asia/Colombo", "Asia/Dhaka", "Asia/Kathmandu", "Europe/London", "Africa/Nairobi", "Africa/Lagos", "America/New_York", "America/Chicago", "America/Los_Angeles", "Australia/Sydney"];

function allZones(): string[] {
  try {
    const f = (Intl as unknown as { supportedValuesOf?: (k: string) => string[] }).supportedValuesOf;
    const z = f ? f("timeZone") : [];
    if (z.length) return Array.from(new Set(["UTC", ...z])).filter((n) => n === "UTC" || /^[A-Za-z_]+\/[A-Za-z0-9_+-]+(\/[A-Za-z0-9_+-]+)?$/.test(n));
  } catch {}
  return COMMON;
}

function nowIn(tz: string): string {
  try {
    return new Intl.DateTimeFormat("en-IN", { timeZone: tz, weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }).format(new Date());
  } catch {
    return "";
  }
}

/** The one place a client sets their time zone. Every date and time in the app follows it. */
export function TimezoneForm({ current, canEdit }: { current: string; canEdit: boolean }) {
  const [tz, setTz] = useState(current);
  const [saved, setSaved] = useState(current);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const zones = useMemo(() => {
    const all = allZones();
    const rest = all.filter((z) => !COMMON.includes(z));
    return { common: COMMON.filter((z) => all.includes(z) || z === current), rest };
  }, [current]);

  return (
    <section className="card space-y-3 p-4">
      <div>
        <h2 className="text-base font-bold">Time zone</h2>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          Set this to where your outlets are. The business day, bill times, reports, offers, gift-card and batch dates, and reminders all follow it.
          It applies to every outlet. To change it, close the open shift first.
        </p>
      </div>
      <div className="flex flex-wrap items-end gap-3">
        <label className="block min-w-[16rem] flex-1">
          <span className="mb-1.5 block text-sm font-semibold">Your time zone</span>
          <select className="field" value={tz} disabled={!canEdit || pending} onChange={(e) => { setTz(e.target.value); setMsg(null); }}>
            {!zones.common.includes(tz) && !zones.rest.includes(tz) && <option value={tz}>{tz}</option>}
            <optgroup label="Common">{zones.common.map((z) => <option key={z} value={z}>{z.replace(/_/g, " ")}</option>)}</optgroup>
            <optgroup label="All time zones">{zones.rest.map((z) => <option key={z} value={z}>{z.replace(/_/g, " ")}</option>)}</optgroup>
          </select>
        </label>
        {canEdit && (
          <button
            className="btn btn-primary"
            disabled={pending || tz === saved}
            onClick={() =>
              start(async () => {
                const r = await setCompanyTimezone(tz);
                if (r.ok) { setSaved(tz); setMsg({ ok: true, text: r.message ?? "Saved." }); }
                else setMsg({ ok: false, text: r.error });
              })
            }
          >
            {pending ? "Saving…" : "Save time zone"}
          </button>
        )}
      </div>
      <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>It is now <b>{nowIn(tz)}</b> there.</p>
      {msg && (
        <div role="status" className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: msg.ok ? "var(--color-ok-soft)" : "var(--color-bad-soft)", color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </div>
      )}
    </section>
  );
}
