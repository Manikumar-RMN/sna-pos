"use client";

import { useState, useTransition } from "react";
import { eraseData, setLive, type SnaResult } from "../../actions";
import { indiaDateTime, toneStyle } from "../../crm";

type Group = { rows: number; tables: Record<string, number> };
export type ErasePreview = {
  live: boolean;
  live_at: string | null;
  live_by: string | null;
  client_code: string;
  trading_name: string;
  bills: number;
  groups: { pos_tx: Group; pos_master: Group; stock_tx: Group; stock_master: Group };
};

type Key = "pos_tx" | "pos_master" | "stock_tx" | "stock_master";

const WHAT: Record<Key, { title: string; removes: string }> = {
  pos_tx: {
    title: "POS transactions",
    removes:
      "Bills, payments, credit notes, kitchen tickets, shifts, cash in / out, day closes, guest QR orders, bookings, timesheets, loyalty points, gift cards, owner alerts and the activity log. The stock those bills used is put back. Bill numbers start again at 0001.",
  },
  pos_master: {
    title: "POS masters",
    removes: "The menu (categories, dishes, options, outlet prices), tables and customers. Recipes of the erased dishes go with them, and the packing charge is switched off.",
  },
  stock_tx: {
    title: "Stock transactions",
    removes: "Every stock entry (purchases, wastage, counts, transfers), purchase orders, goods received and supplier payments. Stock goes back to zero.",
  },
  stock_master: { title: "Stock masters", removes: "Ingredients, recipes and suppliers." },
};

const dark = { background: "var(--color-ink)", color: "#fff" } as const;
const ghost = { border: "1px solid var(--color-line)", color: "var(--color-ink-2)" } as const;
const danger = { background: "var(--color-bad)", color: "#fff" } as const;

function Said({ msg }: { msg: { ok: boolean; text: string } | null }) {
  if (!msg) return null;
  return (
    <p role="status" className="text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
      {msg.text}
    </p>
  );
}

export function ErasePanel({ restaurantId, p, isAdmin }: { restaurantId: string; p: ErasePreview; isAdmin: boolean }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [offReason, setOffReason] = useState("");
  const [askLive, setAskLive] = useState(false);

  // The erase, in three steps: which part → transactions or masters → confirm.
  const [step, setStep] = useState<0 | 1 | 2 | 3>(0);
  const [mod, setMod] = useState({ pos: false, stock: false });
  const [pick, setPick] = useState<Record<Key, boolean>>({ pos_tx: false, pos_master: false, stock_tx: false, stock_master: false });
  const [code, setCode] = useState("");
  const [reason, setReason] = useState("");

  function run(promise: Promise<SnaResult>, after?: () => void) {
    start(async () => {
      const res = await promise;
      setMsg({ ok: res.ok, text: res.ok ? res.message : res.error });
      if (res.ok) after?.();
    });
  }
  function reset() {
    setStep(0);
    setMod({ pos: false, stock: false });
    setPick({ pos_tx: false, pos_master: false, stock_tx: false, stock_master: false });
    setCode("");
    setReason("");
  }
  // Masters cannot go while their transactions stay, so ticking Masters ticks Transactions too.
  function toggle(k: Key) {
    setPick((x) => {
      const next = { ...x, [k]: !x[k] };
      if (next.pos_master) next.pos_tx = true;
      if (next.stock_master) next.stock_tx = true;
      return next;
    });
  }
  const chosen = (Object.keys(pick) as Key[]).filter((k) => pick[k] && ((k.startsWith("pos") && mod.pos) || (k.startsWith("stock") && mod.stock)));
  const totalRows = chosen.reduce((a, k) => a + p.groups[k].rows, 0);

  return (
    <div className="space-y-4">
      {msg && (
        <div className="card p-4">
          <Said msg={msg} />
        </div>
      )}
      {/* ------------------------------------------------ Live switch */}
      <div className="card space-y-3 p-5">
        <h2 className="font-display text-lg font-bold">Go-live</h2>
        <div role="status" className="rounded-2xl px-4 py-3 text-sm font-semibold" style={p.live ? toneStyle.ok : toneStyle.warn}>
          {p.live
            ? `Live since ${p.live_at ? indiaDateTime(p.live_at) : ""}${p.live_by ? `, marked by ${p.live_by}` : ""}. Its data cannot be erased.`
            : "Not live yet. Bills made now are treated as test or training data and can be erased below."}
        </div>
        {!p.live &&
          (askLive ? (
            <div className="flex flex-wrap items-center gap-2 text-sm">
              <span className="font-semibold">Mark {p.trading_name} as Live? After this its data cannot be erased, and only an SNA admin can undo it.</span>
              <button type="button" className="btn h-10 min-h-0 px-4 text-sm" style={dark} disabled={pending} onClick={() => run(setLive(restaurantId, true, ""), () => setAskLive(false))}>
                Yes, mark as Live
              </button>
              <button type="button" className="btn h-10 min-h-0 px-4 text-sm" style={ghost} disabled={pending} onClick={() => setAskLive(false)}>
                Not yet
              </button>
            </div>
          ) : (
            <button type="button" className="btn px-5" style={dark} onClick={() => setAskLive(true)}>
              Mark as Live
            </button>
          ))}
        {p.live &&
          (isAdmin ? (
            <form
              className="flex flex-wrap items-end gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                run(setLive(restaurantId, false, offReason), () => setOffReason(""));
              }}
            >
              <div className="min-w-0 flex-1 basis-72">
                <label htmlFor="live-off-reason" className="mb-1 block text-xs font-bold" style={{ color: "var(--color-ink-2)" }}>
                  Take Live off (admin only). Why?
                </label>
                <input id="live-off-reason" className="field" value={offReason} maxLength={300} required minLength={5} placeholder="e.g. marked live by mistake" onChange={(e) => setOffReason(e.target.value)} />
              </div>
              <button type="submit" className="btn px-4" style={ghost} disabled={pending || offReason.trim().length < 5}>
                Take Live off
              </button>
            </form>
          ) : (
            <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
              Only an SNA admin can take Live off.
            </p>
          ))}
      </div>

      {/* ------------------------------------------------ Erase */}
      <div className="card space-y-4 p-5">
        <h2 className="font-display text-lg font-bold">Erase data</h2>
        {p.live ? (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            This client is live. These are real bills that the restaurant must keep, so nothing can be erased.
          </p>
        ) : step === 0 ? (
          <>
            <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
              For clearing test and training data before a client starts trading. Right now this client has <b>{p.bills}</b> {p.bills === 1 ? "bill" : "bills"}.
              The restaurant itself, its outlets, staff, taxes, payment methods and settings are never erased.
            </p>
            <button
              type="button"
              className="btn px-5"
              style={danger}
              onClick={() => {
                setMsg(null);
                setStep(1);
              }}
            >
              Erase data…
            </button>
          </>
        ) : step === 1 ? (
          <>
            <p className="text-sm font-semibold">Step 1 of 3. Which part of {p.trading_name}?</p>
            <div className="grid gap-3 sm:grid-cols-2">
              {(
                [
                  { k: "pos", title: "POS", sub: "Bills and everything around them; the menu, tables and customers" },
                  { k: "stock", title: "Stock", sub: "Stock entries and purchases; ingredients, recipes and suppliers" },
                ] as const
              ).map((m) => (
                <label key={m.k} className="flex cursor-pointer items-start gap-3 rounded-2xl p-4" style={mod[m.k] ? { border: "2px solid var(--color-ink)" } : { border: "1px solid var(--color-line)" }}>
                  <input type="checkbox" className="mt-1 h-5 w-5" checked={mod[m.k]} onChange={(e) => setMod((x) => ({ ...x, [m.k]: e.target.checked }))} />
                  <span>
                    <span className="block font-bold">{m.title}</span>
                    <span className="text-sm" style={{ color: "var(--color-ink-3)" }}>
                      {m.sub}
                    </span>
                  </span>
                </label>
              ))}
            </div>
            <div className="flex flex-wrap gap-2">
              <button type="button" className="btn px-5" style={dark} disabled={!mod.pos && !mod.stock} onClick={() => setStep(2)}>
                Next
              </button>
              <button type="button" className="btn px-4" style={ghost} onClick={reset}>
                Cancel
              </button>
            </div>
          </>
        ) : step === 2 ? (
          <>
            <p className="text-sm font-semibold">Step 2 of 3. Transactions, masters, or both?</p>
            <div className="space-y-3">
              {(["pos", "stock"] as const)
                .filter((m) => mod[m])
                .map((m) => (
                  <fieldset key={m} className="rounded-2xl p-4" style={{ border: "1px solid var(--color-line)" }}>
                    <legend className="px-1 text-sm font-bold">{m === "pos" ? "POS" : "Stock"}</legend>
                    <div className="space-y-3">
                      {([`${m}_tx`, `${m}_master`] as Key[]).map((k) => {
                        const locked = k.endsWith("_tx") && pick[`${m}_master` as Key];
                        return (
                          <label key={k} className="flex cursor-pointer items-start gap-3">
                            <input type="checkbox" className="mt-1 h-5 w-5" checked={pick[k]} disabled={locked} onChange={() => toggle(k)} />
                            <span className="text-sm">
                              <b>
                                {k.endsWith("_tx") ? "Transactions" : "Masters"} ({p.groups[k].rows} {p.groups[k].rows === 1 ? "record" : "records"})
                              </b>
                              {locked ? " · needed because Masters is ticked" : ""}
                              <span className="block" style={{ color: "var(--color-ink-3)" }}>
                                {WHAT[k].removes}
                              </span>
                            </span>
                          </label>
                        );
                      })}
                    </div>
                  </fieldset>
                ))}
            </div>
            <div className="flex flex-wrap gap-2">
              <button type="button" className="btn px-5" style={dark} disabled={chosen.length === 0} onClick={() => setStep(3)}>
                Next
              </button>
              <button type="button" className="btn px-4" style={ghost} onClick={() => setStep(1)}>
                Back
              </button>
              <button type="button" className="btn px-4" style={ghost} onClick={reset}>
                Cancel
              </button>
            </div>
          </>
        ) : (
          <form
            className="space-y-4"
            onSubmit={(e) => {
              e.preventDefault();
              run(
                eraseData({
                  restaurantId,
                  posTx: chosen.includes("pos_tx"),
                  posMaster: chosen.includes("pos_master"),
                  stockTx: chosen.includes("stock_tx"),
                  stockMaster: chosen.includes("stock_master"),
                  clientCode: code,
                  reason,
                }),
                reset,
              );
            }}
          >
            <p className="text-sm font-semibold">Step 3 of 3. Check and confirm.</p>
            <div className="rounded-2xl p-4 text-sm" style={toneStyle.bad}>
              <b>
                This permanently erases {totalRows} {totalRows === 1 ? "record" : "records"} of {p.trading_name}. It cannot be undone.
              </b>
              <ul className="mt-2 list-disc space-y-1 pl-5" style={{ color: "var(--color-ink)" }}>
                {chosen.map((k) => (
                  <li key={k}>
                    <b>
                      {WHAT[k].title} ({p.groups[k].rows}):
                    </b>{" "}
                    {WHAT[k].removes}
                  </li>
                ))}
              </ul>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <div>
                <label htmlFor="erase-code" className="mb-1 block text-xs font-bold" style={{ color: "var(--color-ink-2)" }}>
                  Type the client code {p.client_code} to confirm
                </label>
                <input id="erase-code" className="field" inputMode="numeric" autoComplete="off" value={code} required onChange={(e) => setCode(e.target.value)} />
              </div>
              <div>
                <label htmlFor="erase-reason" className="mb-1 block text-xs font-bold" style={{ color: "var(--color-ink-2)" }}>
                  Why is this being erased?
                </label>
                <input id="erase-reason" className="field" value={reason} maxLength={300} required minLength={5} placeholder="e.g. training bills before go-live" onChange={(e) => setReason(e.target.value)} />
              </div>
            </div>
            <div className="flex flex-wrap gap-2">
              <button type="submit" className="btn px-5" style={danger} disabled={pending || code.trim() !== p.client_code || reason.trim().length < 5}>
                {pending ? "Erasing…" : "Erase now"}
              </button>
              <button type="button" className="btn px-4" style={ghost} disabled={pending} onClick={() => setStep(2)}>
                Back
              </button>
              <button type="button" className="btn px-4" style={ghost} disabled={pending} onClick={reset}>
                Cancel
              </button>
            </div>
          </form>
        )}
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          Every erase is written to this client&rsquo;s history with who did it, what and why. Ask the restaurant to reload SNA POS on its devices afterwards.
        </p>
      </div>
    </div>
  );
}
