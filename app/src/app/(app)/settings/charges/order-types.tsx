"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { saveOrderTypes } from "../format-actions";

const KINDS = [
  { key: "dine_in", label: "Dine-in", hint: "At a table" },
  { key: "takeaway", label: "Takeaway", hint: "Counter / parcel" },
  { key: "delivery", label: "Delivery", hint: "With address" },
] as const;

/** Settings → Service charge: the kinds of bill this outlet uses and the one the billing screen starts on. */
export function OrderTypesCard({ initial, initialStart, canEdit }: { initial: string[]; initialStart: string; canEdit: boolean }) {
  const [types, setTypes] = useState<string[]>(initial.length ? initial : ["dine_in", "takeaway", "delivery"]);
  const [startOn, setStartOn] = useState(initialStart || "dine_in");
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();

  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Kinds of bill</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Which kinds of bill this outlet uses, and the one the billing screen starts on. A cloud kitchen might use only delivery and
        takeaway; a food court only takeaway.
      </p>
      <fieldset disabled={!canEdit} className="mt-4 grid gap-2 sm:grid-cols-3">
        <legend className="sr-only">Kinds of bill</legend>
        {KINDS.map((k) => {
          const on = types.includes(k.key);
          return (
            <div key={k.key} className="rounded-2xl border px-3.5 py-2 text-sm" style={on ? { borderColor: "var(--color-brand)", background: "var(--color-brand-soft)" } : { borderColor: "var(--color-line)" }}>
              <label className="flex items-center gap-3">
                <input
                  type="checkbox"
                  className="h-5 w-5"
                  checked={on}
                  onChange={() => {
                    const next = on ? types.filter((x) => x !== k.key) : [...types, k.key];
                    setTypes(next);
                    if (!next.includes(startOn) && next[0]) setStartOn(next[0]);
                  }}
                />
                <span>
                  <span className="block font-semibold">{k.label}</span>
                  <span className="block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    {k.hint}
                  </span>
                </span>
              </label>
              {on && (
                <label className="mt-1.5 flex items-center gap-2 text-[11px]">
                  <input type="radio" name="start_on" checked={startOn === k.key} onChange={() => setStartOn(k.key)} />
                  Billing screen starts here
                </label>
              )}
            </div>
          );
        })}
      </fieldset>
      {canEdit && (
        <button
          className="btn btn-primary mt-5"
          disabled={pending || types.length === 0}
          onClick={() =>
            start(async () => {
              const r = await saveOrderTypes(types, startOn);
              setMsg(r.error ? { ok: false, text: r.error } : { ok: true, text: "Saved." });
              if (!r.error) router.refresh();
            })
          }
        >
          {pending ? "Saving…" : "Save changes"}
        </button>
      )}
      {msg && (
        <p className="mt-3 text-sm" role="status" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </p>
      )}
    </section>
  );
}
