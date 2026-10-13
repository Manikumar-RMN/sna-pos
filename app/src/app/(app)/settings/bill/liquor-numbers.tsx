"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { setLiquorPrefix } from "./liquor-actions";

export type LiquorPrefixInfo = { uses_liquor: boolean; prefix: string | null; next_number: string | null };

/** Bars: the prefix of liquor bills (their own number series). */
export function LiquorNumbers({ info }: { info: LiquorPrefixInfo }) {
  const router = useRouter();
  const [v, setV] = useState(info.prefix ?? "");
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const t = v.trim();
  return (
    <section className="card mb-5 p-5">
      <h2 className="text-base font-bold">Liquor bill numbers</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Liquor bills have their own series.{" "}
        {info.next_number ? <>The next liquor bill will be <b>{info.next_number}</b>.</> : <>The first liquor bill will start the series (BAR and the year, unless you set a prefix here).</>}{" "}
        A new prefix starts again from 0001.
      </p>
      <div className="mt-3 flex flex-wrap items-end gap-2">
        <label className="block">
          <span className="mb-1 block text-xs font-semibold">Liquor bill prefix</span>
          <input className="field w-40" maxLength={7} value={v} onChange={(e) => setV(e.target.value.replace(/\s/g, ""))} placeholder="BAR26" />
        </label>
        <button
          className="btn btn-primary"
          disabled={pending || !/^[A-Za-z0-9/]{1,7}$/.test(t) || t === info.prefix}
          onClick={() =>
            start(async () => {
              const r = await setLiquorPrefix(t);
              setMsg(r.ok ? { ok: true, text: `Saved. The next liquor bill will be ${r.next}.` } : { ok: false, text: r.error });
              if (r.ok) router.refresh();
            })
          }
        >
          Save
        </button>
      </div>
      {msg && <p className="mt-2 text-sm" role="status" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>{msg.text}</p>}
    </section>
  );
}
