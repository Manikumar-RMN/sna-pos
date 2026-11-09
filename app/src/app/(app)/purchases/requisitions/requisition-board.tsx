"use client";

import { useRef, useState } from "react";
import { money } from "@/lib/format";
import { Badge, Field, lineStyle, Msg, rowBtn, useRun } from "../ui";
import { decideRequisition, makeOrder, saveApprovalLimit, sendRequisition } from "./actions";

type Ing = { id: string; name: string; unit: string; cost: number };
type PrLine = { name: string; unit: string; qty: number; estCost: number };
export type PrRow = { id: string; number: string; status: string; note: string | null; estTotal: number; createdAt: string; rejectReason: string | null; orderNumber: string | null; lines: PrLine[] };

const STATUS: Record<string, { label: string; bg: string; fg: string }> = {
  pending: { label: "Waiting for approval", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  approved: { label: "Approved", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  ordered: { label: "Ordered", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  rejected: { label: "Turned down", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
  cancelled: { label: "Withdrawn", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
};
const num = (s: string) => {
  const n = Number(s.trim());
  return Number.isFinite(n) && n > 0 ? n : 0;
};

export function RequisitionBoard({ canManage, isOwner, currency, limit, ingredients, suppliers, requisitions }: { canManage: boolean; isOwner: boolean; currency: string; limit: number | null; ingredients: Ing[]; suppliers: { id: string; name: string }[]; requisitions: PrRow[] }) {
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const [asking, setAsking] = useState(false);
  const done = (text: string) => {
    setAsking(false);
    setNote({ ok: true, text });
  };
  return (
    <div className="space-y-5">
      <div className="flex flex-wrap gap-2">
        <button type="button" className="btn btn-primary px-4 text-sm" onClick={() => setAsking(!asking)}>
          New requisition
        </button>
      </div>
      <Msg msg={note} />
      {asking && <NewForm ingredients={ingredients} onDone={done} onClose={() => setAsking(false)} />}
      {isOwner && <LimitBox limit={limit} currency={currency} onDone={done} />}
      <section>
        <h2 className="mb-2 text-sm font-bold">Requisitions</h2>
        <div className="card">
          {requisitions.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              No requisitions yet.
            </p>
          ) : (
            <ul>
              {requisitions.map((r, i) => (
                <Item key={r.id} r={r} first={i === 0} canManage={canManage} currency={currency} suppliers={suppliers} onDone={done} />
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
}

function LimitBox({ limit, currency, onDone }: { limit: number | null; currency: string; onDone: (t: string) => void }) {
  const run = useRun();
  const [v, setV] = useState(limit == null ? "" : String(limit));
  function save() {
    const t = v.trim();
    const n = t === "" ? null : num(t);
    if (t !== "" && n === 0) return run.setMsg({ ok: false, text: "Enter an amount above zero, or leave it empty for no limit." });
    run.run(
      () => saveApprovalLimit(n),
      (x) => {
        onDone(x.message);
        return x.message;
      },
    );
  }
  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Approval limit</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        A manager can approve a requisition up to this amount ({currency}). Above it, only a user who can change settings can approve. Leave empty for no limit.
      </p>
      <div className="mt-2 flex flex-wrap items-end gap-2">
        <Field label="Limit" className="w-40">
          <input className="field h-10 text-sm" inputMode="decimal" value={v} onChange={(e) => setV(e.target.value)} disabled={run.pending} />
        </Field>
        <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={save} disabled={run.pending}>
          {run.pending ? "Saving…" : "Save limit"}
        </button>
      </div>
      <div className="mt-2">
        <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
      </div>
    </section>
  );
}

function Item({ r, first, canManage, currency, suppliers, onDone }: { r: PrRow; first: boolean; canManage: boolean; currency: string; suppliers: { id: string; name: string }[]; onDone: (t: string) => void }) {
  const run = useRun();
  const [open, setOpen] = useState<"none" | "order" | "reject">("none");
  const [reason, setReason] = useState("");
  const [sup, setSup] = useState("");
  const st = STATUS[r.status] ?? STATUS.pending;
  const m = (n: number) => money(n, currency);

  function decide(action: "approve" | "reject" | "cancel") {
    run.run(
      () => decideRequisition(r.id, action, reason),
      (x) => {
        setOpen("none");
        onDone(x.message);
        return x.message;
      },
    );
  }
  function order() {
    if (!sup) return run.setMsg({ ok: false, text: "Choose a supplier." });
    run.run(
      () => makeOrder(r.id, sup),
      (x) => {
        setOpen("none");
        onDone(x.message);
        return x.message;
      },
    );
  }
  return (
    <li className="px-4 py-3" style={first ? undefined : { borderTop: "1px solid var(--color-line)" }}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <span className="font-semibold">{r.number}</span> <Badge label={st.label} bg={st.bg} fg={st.fg} />
          <div className="text-sm" style={{ color: "var(--color-ink-2)" }}>
            {r.createdAt.slice(0, 10)}
            {r.note ? ` · ${r.note}` : ""}
            {r.orderNumber ? ` · order ${r.orderNumber}` : ""}
          </div>
          {r.rejectReason && (
            <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
              Reason: {r.rejectReason}
            </div>
          )}
        </div>
        <span className="font-semibold tabular-nums">{m(r.estTotal)}</span>
      </div>
      <ul className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
        {r.lines.map((l, i) => (
          <li key={i}>
            {l.name}: {l.qty} {l.unit} · about {m(l.estCost)}
          </li>
        ))}
      </ul>
      {open === "none" && (r.status === "pending" || r.status === "approved") && (
        <div className="mt-2 flex flex-wrap gap-2">
          {canManage && r.status === "pending" && (
            <button type="button" className={rowBtn} style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }} onClick={() => decide("approve")} disabled={run.pending}>
              Approve
            </button>
          )}
          {canManage && r.status === "approved" && (
            <button type="button" className={rowBtn} style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }} onClick={() => setOpen("order")} disabled={run.pending}>
              Make purchase order
            </button>
          )}
          {canManage && r.status === "pending" && (
            <button type="button" className={rowBtn} style={{ ...lineStyle, color: "var(--color-bad)" }} onClick={() => setOpen("reject")} disabled={run.pending}>
              Turn down
            </button>
          )}
          {r.status === "pending" && (
            <button type="button" className={rowBtn} style={lineStyle} onClick={() => decide("cancel")} disabled={run.pending}>
              Withdraw
            </button>
          )}
        </div>
      )}
      {open === "order" && (
        <div className="mt-3 rounded-2xl border p-3" style={lineStyle}>
          <Field label="Supplier">
            <select className="field h-10 text-sm" value={sup} onChange={(e) => setSup(e.target.value)} disabled={run.pending}>
              <option value="">Choose supplier…</option>
              {suppliers.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </Field>
          <div className="mt-2">
            <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
          </div>
          <div className="mt-3 flex gap-2">
            <button type="button" className="btn btn-primary px-4 text-sm" onClick={order} disabled={run.pending}>
              {run.pending ? "Saving…" : "Create order"}
            </button>
            <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={() => setOpen("none")} disabled={run.pending}>
              Close
            </button>
          </div>
        </div>
      )}
      {open === "reject" && (
        <div className="mt-3 rounded-2xl border p-3" style={{ borderColor: "var(--color-bad)", background: "var(--color-bad-soft)" }}>
          <Field label="Why is it turned down?">
            <input className="field h-10 text-sm" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} disabled={run.pending} />
          </Field>
          <div className="mt-2">
            <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
          </div>
          <div className="mt-3 flex gap-2">
            <button type="button" className="btn px-4 text-sm" style={{ background: "var(--color-bad)", color: "#fff" }} onClick={() => decide("reject")} disabled={run.pending || reason.trim().length < 3}>
              Turn it down
            </button>
            <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={() => setOpen("none")} disabled={run.pending}>
              Keep it
            </button>
          </div>
        </div>
      )}
      {open === "none" && run.msg && !run.msg.ok && <Msg msg={run.msg} />}
    </li>
  );
}

function NewForm({ ingredients, onDone, onClose }: { ingredients: Ing[]; onDone: (t: string) => void; onClose: () => void }) {
  const run = useRun();
  const [rows, setRows] = useState<{ id: string; qty: string }[]>([{ id: "", qty: "" }, { id: "", qty: "" }, { id: "", qty: "" }]);
  const [note, setNote] = useState("");
  const ref = useRef<string>(crypto.randomUUID());
  const set = (i: number, p: Partial<{ id: string; qty: string }>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...p } : r)));
  function save() {
    const lines = rows.filter((r) => r.id && num(r.qty) > 0).map((r) => ({ ingredient_id: r.id, qty: num(r.qty) }));
    if (rows.some((r) => (r.id && !num(r.qty)) || (!r.id && r.qty.trim() !== ""))) return run.setMsg({ ok: false, text: "Finish or clear every line first." });
    if (lines.length === 0) return run.setMsg({ ok: false, text: "Add at least one ingredient with a quantity." });
    if (new Set(lines.map((l) => l.ingredient_id)).size !== lines.length) return run.setMsg({ ok: false, text: "An ingredient is on the list twice. Put it on one line." });
    run.run(
      () => sendRequisition({ lines, note, clientRef: ref.current }),
      (x) => {
        ref.current = crypto.randomUUID();
        onDone(x.message);
        return x.message;
      },
      "Could not reach the server. Check the connection and tap the button again without changing anything — it will not be saved twice.",
    );
  }
  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">New requisition</h2>
      <ul className="mt-3 space-y-2">
        {rows.map((r, i) => {
          const ing = ingredients.find((x) => x.id === r.id);
          return (
            <li key={i} className="grid grid-cols-[minmax(0,1fr)_110px_auto] items-center gap-2">
              <select className="field h-10 min-w-0 text-sm" value={r.id} onChange={(e) => set(i, { id: e.target.value })} aria-label="Ingredient" disabled={run.pending}>
                <option value="">Ingredient…</option>
                {ingredients.map((x) => (
                  <option key={x.id} value={x.id}>
                    {x.name} ({x.unit})
                  </option>
                ))}
              </select>
              <input className="field h-10 text-sm" inputMode="decimal" placeholder={ing ? `Qty (${ing.unit})` : "Qty"} aria-label="Quantity" value={r.qty} onChange={(e) => set(i, { qty: e.target.value })} disabled={run.pending} />
              <button type="button" className="px-2 text-sm font-bold" style={{ color: "var(--color-bad)" }} onClick={() => setRows(rows.length > 1 ? rows.filter((_, j) => j !== i) : [{ id: "", qty: "" }])} aria-label="Remove line">
                ×
              </button>
            </li>
          );
        })}
      </ul>
      <button type="button" className="btn mt-2 border px-4 text-sm" style={lineStyle} onClick={() => setRows([...rows, { id: "", qty: "" }])}>
        + Another ingredient
      </button>
      <input className="field mt-3 h-10 text-sm" placeholder="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} disabled={run.pending} />
      <div className="mt-2">
        <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <button type="button" className="btn btn-primary px-5 text-sm" onClick={save} disabled={run.pending}>
          {run.pending ? "Saving…" : "Send for approval"}
        </button>
        <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={run.pending}>
          Close
        </button>
      </div>
    </section>
  );
}
