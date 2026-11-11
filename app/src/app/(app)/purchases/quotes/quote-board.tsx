"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { money } from "@/lib/format";
import { awardQuotes, cancelQuoteRequest, createQuoteRequest, saveQuotes } from "./actions";
import { dayLabel, qtyText } from "../helpers";
import { Badge, Confirm, Field, Msg, lineStyle, rowBtn, useRun } from "../ui";

export type RfqSummary = { id: string; number: string; status: string; needed_by: string | null; created_on: string; notes: string | null; items: number; suppliers: number; quoted: number };
export type RfqDetail = {
  id: string;
  number: string;
  status: string;
  needed_by: string | null;
  notes: string | null;
  cancel_reason: string | null;
  suppliers: { id: string; name: string; quoted: boolean }[];
  lines: {
    ingredient_id: string;
    name: string;
    unit: string;
    qty: number | string;
    last_cost: number | string;
    quotes: Record<string, number | string>;
    award: { supplier_id: string; unit_cost: number | string; po_id: string | null; po_number: string | null } | null;
  }[];
};
type Opt = { id: string; name: string };
type Ing = { id: string; name: string; unit: string };

const STATUS: Record<string, { label: string; bg: string; fg: string }> = {
  open: { label: "Waiting for quotes", bg: "var(--color-surface-2)", fg: "var(--color-ink-2)" },
  awarded: { label: "Orders made", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  cancelled: { label: "Cancelled", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
};

export function QuoteBoard({
  requests,
  detail,
  detailError,
  currency,
  today,
  suppliers,
  ingredients,
}: {
  requests: RfqSummary[];
  detail: RfqDetail | null;
  detailError: string | null;
  currency: string;
  today: string;
  suppliers: Opt[];
  ingredients: Ing[];
}) {
  const [creating, setCreating] = useState(false);
  if (detail) return <Compare key={detail.id} rfq={detail} currency={currency} />;
  return (
    <div className="space-y-4">
      {detailError && (
        <p className="rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {detailError}
        </p>
      )}
      {!creating ? (
        <button type="button" className="btn btn-primary px-5 text-sm" onClick={() => setCreating(true)} disabled={suppliers.length < 2 || ingredients.length === 0}>
          New quotation request
        </button>
      ) : (
        <NewRequest suppliers={suppliers} ingredients={ingredients} today={today} onClose={() => setCreating(false)} />
      )}
      {suppliers.length < 2 && (
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          You need at least two active suppliers to compare quotes. Add them under Purchases → Suppliers.
        </p>
      )}
      {requests.length === 0 ? (
        <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          No quotation request yet.
        </div>
      ) : (
        <ul className="space-y-2">
          {requests.map((r) => {
            const s = STATUS[r.status] ?? STATUS.open;
            return (
              <li key={r.id}>
                <Link href={`/purchases/quotes?id=${r.id}`} className="card flex flex-wrap items-center justify-between gap-2 p-4">
                  <span>
                    <span className="font-display font-bold">{r.number}</span>
                    <span className="ml-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                      {r.items} item{r.items === 1 ? "" : "s"} · {r.quoted} of {r.suppliers} suppliers replied · asked {dayLabel(r.created_on)}
                      {r.needed_by ? ` · needed by ${dayLabel(r.needed_by)}` : ""}
                    </span>
                  </span>
                  <Badge label={s.label} bg={s.bg} fg={s.fg} />
                </Link>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

function NewRequest({ suppliers, ingredients, today, onClose }: { suppliers: Opt[]; ingredients: Ing[]; today: string; onClose: () => void }) {
  const { pending, msg, setMsg, run } = useRun();
  const [rows, setRows] = useState<{ id: string; qty: string }[]>([{ id: "", qty: "" }]);
  const [picked, setPicked] = useState<string[]>([]);
  const [neededBy, setNeededBy] = useState("");
  const [notes, setNotes] = useState("");
  const chosen = new Set(rows.map((r) => r.id).filter(Boolean));

  function save() {
    const lines = rows.filter((r) => r.id).map((r) => ({ ingredient_id: r.id, qty: Number(r.qty) }));
    if (lines.length === 0 || lines.some((l) => !(l.qty > 0))) return setMsg({ ok: false, text: "Choose each item and enter a quantity greater than zero." });
    if (picked.length < 2) return setMsg({ ok: false, text: "Choose at least two suppliers to compare." });
    run(() => createQuoteRequest({ lines, supplierIds: picked, neededBy, notes }), (r) => {
      if (r.id) window.location.assign(`/purchases/quotes?id=${r.id}`);
      return r.message;
    });
  }

  return (
    <div className="card p-4">
      <div className="text-sm font-bold">New quotation request</div>
      <div className="mt-3 space-y-2">
        {rows.map((r, i) => (
          <div key={i} className="flex flex-wrap items-end gap-2">
            <Field label={i === 0 ? "Item" : ""} className="min-w-52 flex-1">
              <select className="field h-10 text-sm" value={r.id} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, id: e.target.value } : x)))} disabled={pending}>
                <option value="">Choose an item…</option>
                {ingredients.filter((g) => g.id === r.id || !chosen.has(g.id)).map((g) => (
                  <option key={g.id} value={g.id}>
                    {g.name} ({g.unit})
                  </option>
                ))}
              </select>
            </Field>
            <Field label={i === 0 ? "Quantity" : ""} className="w-28">
              <input className="field h-10 text-sm" inputMode="decimal" value={r.qty} onChange={(e) => setRows(rows.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} disabled={pending} />
            </Field>
            {rows.length > 1 && (
              <button type="button" className={rowBtn} style={lineStyle} onClick={() => setRows(rows.filter((_, j) => j !== i))} disabled={pending}>
                Remove
              </button>
            )}
          </div>
        ))}
        <button type="button" className={rowBtn} style={lineStyle} onClick={() => setRows([...rows, { id: "", qty: "" }])} disabled={pending}>
          Add an item
        </button>
      </div>
      <fieldset className="mt-4">
        <legend className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-2)" }}>
          Ask these suppliers (at least two)
        </legend>
        <div className="flex flex-wrap gap-2">
          {suppliers.map((s) => {
            const on = picked.includes(s.id);
            return (
              <label key={s.id} className="inline-flex min-h-10 items-center gap-2 rounded-xl border px-3 text-sm" style={{ ...lineStyle, background: on ? "var(--color-surface-2)" : undefined }}>
                <input type="checkbox" className="h-5 w-5" checked={on} onChange={() => setPicked(on ? picked.filter((x) => x !== s.id) : [...picked, s.id])} disabled={pending} />
                {s.name}
              </label>
            );
          })}
        </div>
      </fieldset>
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <Field label="Needed by" hint="(optional)">
          <input className="field h-10 text-sm" type="date" min={today} value={neededBy} onChange={(e) => setNeededBy(e.target.value)} disabled={pending} />
        </Field>
        <Field label="Note" hint="(optional)">
          <input className="field h-10 text-sm" value={notes} onChange={(e) => setNotes(e.target.value)} maxLength={300} disabled={pending} />
        </Field>
      </div>
      <div className="mt-3 space-y-2">
        <Msg msg={msg && !msg.ok ? msg : null} />
        <div className="flex flex-wrap gap-2">
          <button type="button" className="btn btn-primary px-4 text-sm" onClick={save} disabled={pending}>
            {pending ? "Saving…" : "Create request"}
          </button>
          <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={pending}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}

function Compare({ rfq, currency }: { rfq: RfqDetail; currency: string }) {
  const m = (n: number) => money(n, currency);
  const open = rfq.status === "open";
  const s = STATUS[rfq.status] ?? STATUS.open;
  const num = (v: number | string | undefined) => (v === undefined || v === null ? null : Number(v));

  // What has been typed in, per supplier and item, starting from what is saved.
  const [typed, setTyped] = useState<Record<string, string>>(() => {
    const o: Record<string, string> = {};
    for (const l of rfq.lines) for (const [sid, v] of Object.entries(l.quotes)) o[`${sid}|${l.ingredient_id}`] = String(Number(v));
    return o;
  });
  const lowest = (l: RfqDetail["lines"][number]) => {
    const rates = Object.values(l.quotes).map(Number);
    return rates.length ? Math.min(...rates) : null;
  };
  // Cheapest saved quote is the starting choice for each item.
  const [pick, setPick] = useState<Record<string, string>>(() => {
    const o: Record<string, string> = {};
    for (const l of rfq.lines) {
      let best: [string, number] | null = null;
      for (const [sid, v] of Object.entries(l.quotes)) if (!best || Number(v) < best[1]) best = [sid, Number(v)];
      if (best) o[l.ingredient_id] = best[0];
    }
    return o;
  });
  const [why, setWhy] = useState("");
  const [note, setNote] = useState<string | null>(null);
  const { pending, msg, setMsg, run } = useRun();

  const total = useMemo(() => {
    let t = 0;
    for (const l of rfq.lines) {
      const sid = pick[l.ingredient_id];
      const rate = sid ? num(l.quotes[sid]) : null;
      if (rate !== null) t += rate * Number(l.qty);
    }
    return Math.round(t * 100) / 100;
  }, [pick, rfq.lines]);
  const bestTotal = useMemo(() => {
    let t = 0;
    for (const l of rfq.lines) {
      const lo = lowest(l);
      if (lo !== null) t += lo * Number(l.qty);
    }
    return Math.round(t * 100) / 100;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rfq.lines]);

  function saveSupplier(sid: string) {
    const rates = rfq.lines.map((l) => ({ ingredient_id: l.ingredient_id, unit_cost: typed[`${sid}|${l.ingredient_id}`] ?? "" }));
    run(() => saveQuotes({ rfqId: rfq.id, supplierId: sid, rates }), (r) => {
      window.location.reload();
      return r.message;
    });
  }
  function award(place: boolean) {
    const awards = rfq.lines.filter((l) => pick[l.ingredient_id]).map((l) => ({ ingredient_id: l.ingredient_id, supplier_id: pick[l.ingredient_id] }));
    if (awards.length === 0) return setMsg({ ok: false, text: "Choose a supplier for at least one item." });
    run(() => awardQuotes({ rfqId: rfq.id, awards, place }), (r) => {
      setNote(r.message);
      return r.message;
    });
  }

  return (
    <div className="space-y-4">
      <Link href="/purchases/quotes" className="text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
        ← All requests
      </Link>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h2 className="font-display text-lg font-bold">{rfq.number}</h2>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            {rfq.needed_by ? `Needed by ${dayLabel(rfq.needed_by)}` : "No needed-by date"}
            {rfq.notes ? ` · ${rfq.notes}` : ""}
            {rfq.cancel_reason ? ` · Cancelled: ${rfq.cancel_reason}` : ""}
          </p>
        </div>
        <Badge label={s.label} bg={s.bg} fg={s.fg} />
      </div>
      {note && <Msg msg={{ ok: true, text: note }} />}

      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <caption className="sr-only">Rates quoted by each supplier, per item</caption>
          <thead>
            <tr style={{ color: "var(--color-ink-3)" }}>
              <th className="px-3 py-2 text-left text-xs font-semibold">Item</th>
              <th className="px-3 py-2 text-right text-xs font-semibold">Quantity</th>
              <th className="px-3 py-2 text-right text-xs font-semibold">Last cost</th>
              {rfq.suppliers.map((sp) => (
                <th key={sp.id} className="px-3 py-2 text-left text-xs font-semibold">
                  {sp.name}
                </th>
              ))}
              {!open && <th className="px-3 py-2 text-left text-xs font-semibold">Ordered from</th>}
            </tr>
          </thead>
          <tbody>
            {rfq.lines.map((l) => {
              const lo = lowest(l);
              return (
                <tr key={l.ingredient_id} style={{ borderTop: "1px solid var(--color-line)" }}>
                  <td className="px-3 py-2">{l.name}</td>
                  <td className="px-3 py-2 text-right tabular-nums">
                    {qtyText(l.qty)} {l.unit}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums">{m(Number(l.last_cost))}</td>
                  {rfq.suppliers.map((sp) => {
                    const saved = num(l.quotes[sp.id]);
                    const best = saved !== null && lo !== null && saved === lo && Object.keys(l.quotes).length > 1;
                    const chosen = pick[l.ingredient_id] === sp.id;
                    return (
                      <td key={sp.id} className="px-3 py-2" style={best ? { background: "var(--color-ok-soft)" } : undefined}>
                        {open ? (
                          <div className="flex items-center gap-2">
                            <input
                              aria-label={`${sp.name} rate for ${l.name}`}
                              className="field h-10 w-24 text-sm"
                              inputMode="decimal"
                              placeholder="—"
                              value={typed[`${sp.id}|${l.ingredient_id}`] ?? ""}
                              onChange={(e) => setTyped({ ...typed, [`${sp.id}|${l.ingredient_id}`]: e.target.value })}
                              disabled={pending}
                            />
                            {saved !== null && (
                              <label className="inline-flex min-h-10 items-center gap-1 text-xs">
                                <input type="radio" className="h-5 w-5" name={`pick-${l.ingredient_id}`} checked={chosen} onChange={() => setPick({ ...pick, [l.ingredient_id]: sp.id })} disabled={pending} />
                                Buy
                              </label>
                            )}
                          </div>
                        ) : saved !== null ? (
                          <span className="tabular-nums">{m(saved)}</span>
                        ) : (
                          "—"
                        )}
                        {best && (
                          <div className="text-xs font-semibold" style={{ color: "var(--color-ok)" }}>
                            Lowest
                          </div>
                        )}
                      </td>
                    );
                  })}
                  {!open && (
                    <td className="px-3 py-2 text-xs">
                      {l.award ? `${rfq.suppliers.find((x) => x.id === l.award!.supplier_id)?.name ?? "Supplier"} · ${l.award.po_number ?? ""}` : "—"}
                    </td>
                  )}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {open && (
        <>
          <div className="flex flex-wrap gap-2">
            {rfq.suppliers.map((sp) => (
              <button key={sp.id} type="button" className={rowBtn} style={lineStyle} onClick={() => saveSupplier(sp.id)} disabled={pending}>
                Save {sp.name}&rsquo;s rates{sp.quoted ? " ✓" : ""}
              </button>
            ))}
          </div>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Type a rate (before tax, per stock unit) and tap that supplier&rsquo;s Save button. Leave a box empty if they did not quote that item. After saving, the lowest rate is marked and chosen to buy; change the choice with the Buy buttons.
          </p>
          <div className="card p-4">
            <div className="text-sm">
              Buying the chosen rates comes to <b className="tabular-nums">{m(total)}</b>
              {bestTotal > 0 && total > bestTotal ? <span style={{ color: "var(--color-ink-3)" }}> (cheapest possible: {m(bestTotal)})</span> : null}. One purchase order is made for each supplier you chose.
            </div>
            <div className="mt-3 space-y-2">
              <Msg msg={msg && !msg.ok ? msg : null} />
              <div className="flex flex-wrap gap-2">
                <button type="button" className="btn btn-primary px-4 text-sm" onClick={() => award(false)} disabled={pending}>
                  {pending ? "Saving…" : "Make draft orders"}
                </button>
                <Confirm danger={false} question="Send the orders to the suppliers now?" yes="Send orders" no="Not yet" disabled={pending} onYes={() => award(true)}>
                  Make and send orders
                </Confirm>
                <Confirm question="Cancel this request?" yes="Cancel it" disabled={pending} onYes={() => run(() => cancelQuoteRequest(rfq.id, why.trim().length >= 3 ? why : "No longer needed"), (r) => {
                  window.location.reload();
                  return r.message;
                })}>
                  Cancel request
                </Confirm>
              </div>
              <Field label="Reason for cancelling" hint="(optional)" className="max-w-sm">
                <input className="field h-10 text-sm" value={why} onChange={(e) => setWhy(e.target.value)} maxLength={300} placeholder="No longer needed" disabled={pending} />
              </Field>
            </div>
          </div>
        </>
      )}
      {!open && rfq.status === "awarded" && (
        <p className="text-sm">
          The orders are on the{" "}
          <Link href="/purchases?tab=orders" className="font-semibold" style={{ color: "var(--color-brand)" }}>
            Orders tab
          </Link>
          .
        </p>
      )}
    </div>
  );
}
