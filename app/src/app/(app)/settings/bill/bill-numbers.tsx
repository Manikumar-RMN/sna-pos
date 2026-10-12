"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { setBillPrefix } from "../actions";

export type BillPrefixInfo = {
  prefix: string;
  next_number: string;
  bills_in_series: number;
  earlier: { prefix: string; last_number: string | null }[];
};

const OK = /^[A-Za-z0-9/]{1,7}$/;

/**
 * Settings → Bill layout: the bill prefix. Bills are numbered <prefix>-0001, -0002, … by themselves.
 * A new prefix (for example at the start of a financial year) starts again from 0001; going back to a
 * prefix used before carries on where it stopped, so a number is never given twice.
 */
export function BillNumbers({ info, isIndia }: { info: BillPrefixInfo; isIndia: boolean }) {
  const router = useRouter();
  const [v, setV] = useState(info.prefix);
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const t = v.trim();
  const valid = OK.test(t);
  const earlier = info.earlier.find((e) => e.prefix.toUpperCase() === t.toUpperCase());
  const changed = t !== info.prefix;

  function save() {
    setMsg(null);
    start(async () => {
      const r = await setBillPrefix(t);
      if (r.ok) {
        setMsg({ ok: true, text: r.message ?? "Saved." });
        router.refresh();
      } else setMsg({ ok: false, text: r.error });
    });
  }

  return (
    <section className="card mb-5 p-5">
      <h2 className="text-base font-bold">Bill numbers</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Every bill gets the prefix and the next number by itself. The next bill will be <b>{info.next_number}</b>
        {info.bills_in_series > 0 ? ` (${info.bills_in_series} ${info.bills_in_series === 1 ? "bill" : "bills"} made with ${info.prefix} so far)` : ""}.
      </p>
      <label className="mt-4 block max-w-xs">
        <span className="mb-1 block text-xs font-semibold">Bill prefix</span>
        <input className="field" value={v} maxLength={7} onChange={(e) => setV(e.target.value.replace(/\s/g, ""))} aria-describedby="bp-hint" />
        <span id="bp-hint" className="mt-1 block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
          1 to 7 letters, digits or &ldquo;/&rdquo;, for example BILL26 or INV/27.{isIndia ? " This keeps every bill number within GST's 16 characters." : ""}
        </span>
      </label>
      {changed && valid && (
        <p className="mt-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-ground)", color: "var(--color-ink-2)" }}>
          {earlier
            ? `${earlier.prefix} was used before${earlier.last_number ? ` (last bill ${earlier.last_number})` : ""}. Bills will carry on from there.`
            : `The next bill will be ${t}-0001. Bills already made keep their numbers.`}
          {isIndia && !earlier ? " Change the prefix at the start of a financial year if your accountant wants the numbers to start again from 1." : ""}
        </p>
      )}
      {changed && !valid && t.length > 0 && (
        <p className="mt-3 text-xs" style={{ color: "var(--color-bad)" }}>
          Use only letters, digits or &ldquo;/&rdquo; (no spaces or &ldquo;-&rdquo;), up to 7.
        </p>
      )}
      <button className="btn btn-primary mt-4" disabled={pending || !changed || !valid} onClick={save}>
        {pending ? "Saving…" : "Save prefix"}
      </button>
      {msg && (
        <p
          className="mt-3 rounded-lg px-3 py-2 text-sm"
          role={msg.ok ? "status" : "alert"}
          style={{ background: msg.ok ? "var(--color-ok-soft)" : "var(--color-bad-soft)", color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}
        >
          {msg.text}
        </p>
      )}
      {info.earlier.length > 0 && (
        <div className="mt-4 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Used before: {info.earlier.map((e) => `${e.prefix}${e.last_number ? ` (last ${e.last_number})` : ""}`).join(", ")}
        </div>
      )}
    </section>
  );
}
