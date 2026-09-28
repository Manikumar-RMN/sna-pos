"use client";

import { useState, useTransition } from "react";
import { LANGS } from "@/lib/i18n";
import { setDeviceLanguage, setSecondLanguage } from "../actions";

/** Second language under the English words: one choice for the restaurant, and an optional one per device. */
export function LanguageForm({ restaurant, device, canEdit }: { restaurant: string; device: string; canEdit: boolean }) {
  const [rest, setRest] = useState(restaurant);
  const [dev, setDev] = useState(device);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();

  const run = (fn: () => Promise<{ ok: true; message?: string } | { ok: false; error: string }>) =>
    start(async () => {
      const r = await fn();
      setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
    });

  const options = LANGS.map((l) => (
    <option key={l.code} value={l.code}>
      {l.name} — {l.native} ({l.region})
    </option>
  ));

  return (
    <section className="card space-y-4 p-4">
      <div>
        <h2 className="text-base font-bold">Second language</h2>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          English always comes first. The second language is shown in small type underneath on buttons, the kitchen screen and
          dish names. Type each dish&apos;s local name in Settings → Menu.
        </p>
      </div>
      <div className="grid gap-3 sm:grid-cols-2">
        <label className="block">
          <span className="mb-1.5 block text-sm font-semibold">For the whole restaurant</span>
          <select
            className="field"
            value={rest}
            disabled={!canEdit || pending}
            onChange={(e) => {
              setRest(e.target.value);
              run(() => setSecondLanguage(e.target.value));
            }}
          >
            <option value="">English only</option>
            {options}
          </select>
        </label>
        <label className="block">
          <span className="mb-1.5 block text-sm font-semibold">This device only</span>
          <select
            className="field"
            value={dev}
            disabled={pending}
            onChange={(e) => {
              setDev(e.target.value);
              run(() => setDeviceLanguage(e.target.value));
            }}
          >
            <option value="">Same as the restaurant</option>
            <option value="none">English only</option>
            {options}
          </select>
        </label>
      </div>
      <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
        Screen words are machine-checked translations; a native speaker should review them before launch in each market.
      </p>
      {msg && (
        <p role="status" className="text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </p>
      )}
    </section>
  );
}
