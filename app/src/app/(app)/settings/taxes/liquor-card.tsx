"use client";

import { useState, useTransition } from "react";
import { setLiquorGroup } from "./liquor-actions";

/** Bars: which tax groups are liquor (state VAT, separate bills). */
export function LiquorCard({ groups, canEdit }: { groups: { id: string; name: string; separate_bill: boolean }[]; canEdit: boolean }) {
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <section className="card mt-4 p-4">
      <h2 className="text-sm font-bold">Bars: liquor on separate bills</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Liquor is not under GST; it is taxed by the state (VAT) and billed separately. Make a tax group for liquor with your state&rsquo;s VAT rate,
        put the drinks in it, and tick it here. Those drinks then go only on liquor bills, numbered in their own series (set in Settings → Bill layout).
        Food and liquor are never mixed on one bill. Please confirm the VAT rate for your state with your tax adviser.
      </p>
      <div className="mt-3 flex flex-wrap gap-2">
        {groups.map((g) => (
          <label key={g.id} className="flex items-center gap-2 rounded-lg border px-3 py-2 text-sm" style={{ borderColor: "var(--color-line)" }}>
            <input
              type="checkbox"
              defaultChecked={g.separate_bill}
              disabled={!canEdit || pending}
              onChange={(e) => {
                const on = e.target.checked;
                start(async () => {
                  const r = await setLiquorGroup(g.id, on);
                  setError(r.error);
                });
              }}
            />
            {g.name} {g.separate_bill && <span className="text-xs font-semibold" style={{ color: "var(--color-brand)" }}>liquor</span>}
          </label>
        ))}
      </div>
      {error && <p className="mt-2 text-xs" role="alert" style={{ color: "var(--color-bad)" }}>{error}</p>}
    </section>
  );
}
