"use client";

import Link from "next/link";
import { useState, useTransition } from "react";
import { goLiveTick, setLive, type SnaResult } from "../../actions";
import { indiaDateTime, toneStyle } from "../../crm";

export type GoLiveItem = {
  key: string;
  group: string;
  title: string;
  auto: boolean;
  post: boolean;
  note_label: string | null;
  hint: string | null;
  ok: boolean;
  detail: string | null;
  by: string | null;
  at: string | null;
  note: string | null;
};
export type GoLiveStatus = {
  live: boolean;
  live_at: string | null;
  live_by: string | null;
  business_type: string;
  total: number;
  done: number;
  ready: boolean;
  open: string[];
  items: GoLiveItem[];
};

const dark = { background: "var(--color-ink)", color: "#fff" } as const;
const ghost = { border: "1px solid var(--color-line)", color: "var(--color-ink-2)" } as const;

/** A thin progress bar with the count beside it. Used here and on the Overview tab. */
export function GoLiveBar({ done, total }: { done: number; total: number }) {
  const pct = total > 0 ? Math.round((done / total) * 100) : 0;
  return (
    <div className="flex items-center gap-3">
      <div role="progressbar" aria-label="Go-live checklist" aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct} className="h-2.5 w-40 max-w-full overflow-hidden rounded-full" style={{ background: "var(--color-line)" }}>
        <div className="h-full rounded-full" style={{ width: `${pct}%`, background: "var(--color-ok)" }} />
      </div>
      <span className="text-sm font-bold">
        {done} of {total}
      </span>
    </div>
  );
}

/** The Overview tab's one line about go-live. */
export function GoLiveLine({ restaurantId, st }: { restaurantId: string; st: GoLiveStatus }) {
  return (
    <div className="card flex flex-wrap items-center justify-between gap-3 p-5">
      <div>
        <h2 className="font-display text-lg font-bold">Go-live</h2>
        {st.live ? (
          <p className="text-sm font-semibold" style={{ color: "var(--color-ok)" }}>
            Live since {st.live_at ? indiaDateTime(st.live_at) : ""}
            {st.live_by ? `, marked by ${st.live_by}` : ""}.
          </p>
        ) : (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            Not live yet. {st.total - st.done === 0 ? "The checklist is complete." : `${st.total - st.done} checklist ${st.total - st.done === 1 ? "item is" : "items are"} still open.`}
          </p>
        )}
      </div>
      <div className="flex flex-wrap items-center gap-4">
        {!st.live && <GoLiveBar done={st.done} total={st.total} />}
        <Link href={`/sna/r/${restaurantId}?tab=golive`} className="text-sm font-bold" style={{ color: "var(--color-brand)" }}>
          {st.live ? "Open the checklist" : "Open the checklist →"}
        </Link>
      </div>
    </div>
  );
}

/** The go-live checklist. Items marked Automatic tick themselves from the client's own setup. */
export function GoLivePanel({ restaurantId, st, isAdmin }: { restaurantId: string; st: GoLiveStatus; isAdmin: boolean }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [notes, setNotes] = useState<Record<string, string>>(() => Object.fromEntries(st.items.map((i) => [i.key, i.note ?? ""])));
  const [askLive, setAskLive] = useState(false);
  const [why, setWhy] = useState("");

  function run(p: Promise<SnaResult>, after?: () => void) {
    start(async () => {
      const r = await p;
      setMsg({ ok: r.ok, text: r.ok ? r.message : r.error });
      if (r.ok) after?.();
    });
  }

  // Numbers count only the items shown for this type of business, so they run 1, 2, 3 with no gaps.
  const numbered = st.items.map((it, i) => ({ it, n: i + 1 }));
  const groups: { name: string; rows: { it: GoLiveItem; n: number }[] }[] = [];
  for (const row of numbered) {
    const last = groups[groups.length - 1];
    if (last && last.name === row.it.group) last.rows.push(row);
    else groups.push({ name: row.it.group, rows: [row] });
  }
  const left = st.total - st.done;

  const liveBox = (
    <section key="live" className="card space-y-3 p-5">
      <h2 className="font-display text-lg font-bold">Mark as Live</h2>
      {st.live ? (
        <div role="status" className="rounded-2xl px-4 py-3 text-sm font-semibold" style={toneStyle.ok}>
          Live since {st.live_at ? indiaDateTime(st.live_at) : ""}
          {st.live_by ? `, marked by ${st.live_by}` : ""}. Its data cannot be erased.
        </div>
      ) : (
        <>
          <div role="status" className="rounded-2xl px-4 py-3 text-sm font-semibold" style={st.ready ? toneStyle.ok : toneStyle.warn}>
            {st.ready ? "All items are done. This client can go Live." : `${left} ${left === 1 ? "item is" : "items are"} still open, so Live is switched off.`}
          </div>
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            After this, the client&apos;s data cannot be erased, and only an SNA admin can undo it. Do the erase of test bills first.
          </p>
          {askLive ? (
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-semibold">Mark this client as Live? Its data can then no longer be erased.</span>
              <button type="button" className="btn h-10 min-h-0 px-4 text-sm" style={dark} disabled={pending} onClick={() => run(setLive(restaurantId, true, ""), () => setAskLive(false))}>
                Yes, mark as Live
              </button>
              <button type="button" className="btn h-10 min-h-0 px-4 text-sm" style={ghost} disabled={pending} onClick={() => setAskLive(false)}>
                Not yet
              </button>
            </div>
          ) : (
            <button type="button" className="btn px-5" style={dark} disabled={!st.ready || pending} onClick={() => setAskLive(true)}>
              Mark as Live
            </button>
          )}
          {!st.ready &&
            (isAdmin ? (
              <form
                className="space-y-2 border-t pt-3"
                style={{ borderColor: "var(--color-line)" }}
                onSubmit={(e) => {
                  e.preventDefault();
                  run(setLive(restaurantId, true, why), () => setWhy(""));
                }}
              >
                <label htmlFor="golive-why" className="block text-xs font-bold" style={{ color: "var(--color-ink-2)" }}>
                  Admin only: go Live with items still open. Why? The reason is saved in the client&apos;s history.
                </label>
                <div className="flex flex-wrap items-end gap-2">
                  <input id="golive-why" className="field min-w-0 flex-1 basis-72" value={why} maxLength={300} placeholder="e.g. owner brings the printer on day two" onChange={(e) => setWhy(e.target.value)} />
                  <button type="submit" className="btn px-4" style={ghost} disabled={pending || why.trim().length < 5}>
                    Go Live anyway
                  </button>
                </div>
              </form>
            ) : (
              <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                Only an SNA admin can go Live with items still open.
              </p>
            ))}
        </>
      )}
    </section>
  );

  let liveShown = false;
  const out: React.ReactNode[] = [];
  for (const g of groups) {
    const post = g.rows.every((r) => r.it.post);
    if (post && !liveShown) {
      out.push(liveBox);
      liveShown = true;
    }
    const inGroup = g.rows.filter((r) => r.it.ok).length;
    out.push(
      <section key={g.name} className="card overflow-hidden">
        <div className="flex flex-wrap items-baseline justify-between gap-2 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)" }}>
          <div>
            <h2 className="font-display text-base font-bold">{g.name}</h2>
            {post && (
              <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                Does not block Live. Opens once the client is Live.
              </div>
            )}
          </div>
          {!post && (
            <span className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              {inGroup} of {g.rows.length}
            </span>
          )}
        </div>
        <ul className="divide-y" style={{ borderColor: "var(--color-line)" }}>
          {g.rows.map(({ it, n }) => {
            const locked = it.post ? !st.live : st.live;
            return (
              <li key={it.key} className="flex gap-3 px-4 py-3">
                <span className="w-6 flex-none pt-0.5 text-right text-xs font-semibold tabular-nums" style={{ color: "var(--color-ink-3)" }}>
                  {n}
                </span>
                <div className="min-w-0 flex-1 space-y-1.5">
                  {it.auto ? (
                    <div className="flex items-start gap-2.5">
                      <span aria-hidden className="mt-0.5 flex h-5 w-5 flex-none items-center justify-center rounded-full text-xs font-bold" style={it.ok ? toneStyle.ok : toneStyle.bad}>
                        {it.ok ? "✓" : "!"}
                      </span>
                      <div className="min-w-0">
                        <div className="text-sm font-semibold">{it.title}</div>
                        <div className="mt-1 flex flex-wrap items-center gap-2 text-xs">
                          <span className="rounded-md px-2 py-0.5 font-bold" style={toneStyle.plain}>
                            Automatic
                          </span>
                          {it.ok ? (
                            <span className="font-semibold" style={{ color: "var(--color-ok)" }}>
                              Found in the client&apos;s setup
                            </span>
                          ) : (
                            <span className="font-semibold" style={{ color: "var(--color-bad)" }}>
                              {it.detail ?? "Not done yet"}. Fix it in the restaurant&apos;s own Setup.
                            </span>
                          )}
                        </div>
                      </div>
                    </div>
                  ) : (
                    <>
                      <div className="flex items-start gap-2.5">
                        <input
                          id={`gl-${it.key}`}
                          type="checkbox"
                          className="mt-0.5 h-5 w-5 flex-none"
                          checked={it.ok}
                          disabled={pending || locked}
                          onChange={(e) => run(goLiveTick(restaurantId, it.key, e.target.checked, notes[it.key] ?? ""))}
                        />
                        <label htmlFor={`gl-${it.key}`} className="text-sm font-semibold">
                          {it.title}
                        </label>
                      </div>
                      {it.hint && (
                        <div className="pl-7 text-xs" style={{ color: "var(--color-ink-3)" }}>
                          {it.hint}
                        </div>
                      )}
                      {it.note_label && (
                        <div className="pl-7">
                          <label htmlFor={`gln-${it.key}`} className="mb-1 block text-xs font-semibold" style={{ color: "var(--color-ink-2)" }}>
                            {it.note_label} (optional)
                          </label>
                          <input
                            id={`gln-${it.key}`}
                            className="field h-10 w-full max-w-sm"
                            maxLength={200}
                            value={notes[it.key] ?? ""}
                            disabled={pending || locked}
                            onChange={(e) => setNotes({ ...notes, [it.key]: e.target.value })}
                            onBlur={() => it.ok && (notes[it.key] ?? "") !== (it.note ?? "") && run(goLiveTick(restaurantId, it.key, true, notes[it.key] ?? ""))}
                          />
                        </div>
                      )}
                      {it.ok && it.by && it.at && (
                        <div className="pl-7 text-xs" style={{ color: "var(--color-ink-3)" }}>
                          Ticked by {it.by} on {indiaDateTime(it.at)}
                        </div>
                      )}
                    </>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      </section>,
    );
  }
  if (!liveShown) out.push(liveBox);

  return (
    <div className="space-y-4">
      {msg && (
        <div className="card p-4">
          <p role="status" className="text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
            {msg.text}
          </p>
        </div>
      )}
      <section className="card space-y-2 p-5" aria-live="polite">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <h2 className="font-display text-lg font-bold">Go-live checklist</h2>
          <GoLiveBar done={st.done} total={st.total} />
        </div>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          Items marked Automatic tick themselves from the client&apos;s setup. The rest are ticked by SNA staff, and the console keeps who and when. Items that do not apply to this type of business are hidden.
        </p>
      </section>
      {out}
    </div>
  );
}
