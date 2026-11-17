"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { saveStockSettings } from "../actions";

export function StockOnSaleForm({ initial }: { initial: boolean }) {
  const router = useRouter();
  const [on, setOn] = useState(initial);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  return (
    <section className="card space-y-4 p-4">
      <h2 className="text-base font-bold">Take stock when a bill is made</h2>
      <fieldset className="space-y-2 text-sm">
        <label className="flex items-start gap-3">
          <input type="radio" name="autoc" className="mt-1 h-5 w-5" checked={on} onChange={() => setOn(true)} />
          <span>
            <span className="block font-semibold">Yes (recommended)</span>
            <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
              When an item is sold, its recipe is taken out of stock. A cancelled item or voided bill puts it back. Items with no recipe take nothing, so to track only liquor, give recipes only to the liquor items (for example one peg = 30 ml of the bottle).
            </span>
          </span>
        </label>
        <label className="flex items-start gap-3">
          <input type="radio" name="autoc" className="mt-1 h-5 w-5" checked={!on} onChange={() => setOn(false)} />
          <span>
            <span className="block font-semibold">No</span>
            <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
              Bills never change stock. Stock changes only by purchases, issues, wastage and counts that someone enters.
            </span>
          </span>
        </label>
      </fieldset>
      <button
        className="btn btn-primary"
        disabled={pending}
        onClick={() =>
          start(async () => {
            const r = await saveStockSettings(on);
            setMsg(r.ok ? { ok: true, text: r.message ?? "Saved." } : { ok: false, text: r.error });
            if (r.ok) router.refresh();
          })
        }
      >
        Save
      </button>
      {msg && (
        <p role={msg.ok ? "status" : "alert"} className="text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </p>
      )}
    </section>
  );
}
