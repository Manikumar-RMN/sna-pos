"use client";

import { useState, useTransition } from "react";
import { addKiosk, removeKiosk, setKioskAuto } from "./kiosk-actions";

/** Self-order kiosks: a tablet at the counter where guests order for takeaway and pay at the counter. */
export function Kiosks({
  kiosks,
  origin,
  staff,
}: {
  kiosks: { id: string; name: string; token: string; auto_user: string | null }[];
  origin: string;
  /** Staff logins (email sign-in) allowed to take orders: a kiosk can bill as one of them. */
  staff: { id: string; name: string }[];
}) {
  const [name, setName] = useState(`Kiosk ${kiosks.length + 1}`);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <section className="card mt-6 p-4">
      <h2 className="text-sm font-bold">Self-order kiosks</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Put a tablet at the counter and open its link in the browser (full screen). Guests choose dishes and send the order; it appears on the
        Table orders screen, and accepting it makes a takeaway bill and the kitchen ticket. The kiosk then shows the guest&rsquo;s bill and token number
        to pay at the counter, and clears itself for the next guest. Choose &ldquo;Bill at once as …&rdquo; to skip the staff tap: the bill and
        kitchen ticket are made the moment the guest orders (if anything stops it, the order waits on Table orders as usual).
      </p>
      <div className="mt-3 space-y-2">
        {kiosks.map((k) => {
          const url = `${origin}/t/${k.token}`;
          return (
            <div key={k.id} className="flex flex-wrap items-center gap-2 text-sm">
              <b className="w-24">{k.name}</b>
              <code className="max-w-full truncate rounded px-2 py-1 text-xs" style={{ background: "var(--color-ground)" }}>{url}</code>
              <button
                className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
                style={{ borderColor: "var(--color-line)" }}
                onClick={() => {
                  navigator.clipboard?.writeText(url).then(() => setCopied(k.id)).catch(() => {});
                }}
              >
                {copied === k.id ? "Copied" : "Copy link"}
              </button>
              <a className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} href={url} target="_blank" rel="noreferrer">
                Open
              </a>
              <select
                className="field w-56"
                value={k.auto_user ?? ""}
                disabled={pending}
                aria-label={`How ${k.name} orders become bills`}
                onChange={(e) => {
                  const v = e.target.value || null;
                  start(async () => setError((await setKioskAuto(k.id, v)).error));
                }}
              >
                <option value="">Staff accept each order</option>
                {staff.map((u) => (
                  <option key={u.id} value={u.id}>Bill at once as {u.name}</option>
                ))}
              </select>
              <button
                className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
                style={{ borderColor: "var(--color-line)", color: "var(--color-bad)" }}
                disabled={pending}
                onClick={() => start(async () => setError((await removeKiosk(k.id)).error))}
              >
                Remove
              </button>
            </div>
          );
        })}
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <input className="field w-40" maxLength={20} value={name} onChange={(e) => setName(e.target.value)} aria-label="Kiosk name" />
        <button className="btn btn-primary" disabled={pending || !name.trim()} onClick={() => start(async () => setError((await addKiosk(name)).error))}>
          Add kiosk
        </button>
      </div>
      {error && <p className="mt-2 text-xs" role="alert" style={{ color: "var(--color-bad)" }}>{error}</p>}
    </section>
  );
}
