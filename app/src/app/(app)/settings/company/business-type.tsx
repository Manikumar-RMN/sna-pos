"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { BUSINESS_TYPES } from "@/lib/business-types";
import { saveBusinessType } from "../format-actions";

/** Settings → Company: what kind of business this is. Choosing a type can set the matching starting settings. */
export function BusinessTypeCard({ initial, canEdit }: { initial: string; canEdit: boolean }) {
  const [type, setType] = useState(initial || "restaurant");
  const [apply, setApply] = useState(true);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();

  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Type of business</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        SNA POS works for every kind of food business. The type sets sensible starting settings — which kinds of bill the billing screen
        offers, which one it starts on, and token numbers. You can change each of them afterwards.
      </p>
      <fieldset disabled={!canEdit} className="mt-4 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        <legend className="sr-only">Type of business</legend>
        {BUSINESS_TYPES.map((t) => {
          const on = type === t.key;
          return (
            <label
              key={t.key}
              className="flex min-h-14 items-center gap-3 rounded-2xl border px-3.5 py-2 text-sm"
              style={on ? { borderColor: "var(--color-brand)", background: "var(--color-brand-soft)" } : { borderColor: "var(--color-line)" }}
            >
              <input type="radio" name="business_type" className="h-5 w-5 shrink-0" checked={on} onChange={() => setType(t.key)} />
              <span>
                <span className="block font-semibold">{t.label}</span>
                <span className="block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                  {t.hint}
                </span>
              </span>
            </label>
          );
        })}
      </fieldset>
      {canEdit && (
        <>
          <label className="mt-4 flex items-center gap-2 text-sm">
            <input type="checkbox" className="h-4 w-4" checked={apply} onChange={(e) => setApply(e.target.checked)} />
            Also put this type&rsquo;s starting settings on every outlet (kinds of bill, token numbers)
          </label>
          <button
            className="btn btn-primary mt-4"
            disabled={pending}
            onClick={() =>
              start(async () => {
                const r = await saveBusinessType(type, apply);
                setMsg(r.error ? { ok: false, text: r.error } : { ok: true, text: apply ? "Saved. The starting settings are on every outlet." : "Saved." });
                if (!r.error) router.refresh();
              })
            }
          >
            {pending ? "Saving…" : "Save type of business"}
          </button>
        </>
      )}
      {msg && (
        <p className="mt-3 text-sm" role="status" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </p>
      )}
    </section>
  );
}
