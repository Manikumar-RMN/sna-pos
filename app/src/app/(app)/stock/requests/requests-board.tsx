"use client";

import { useRef, useState } from "react";
import { money } from "@/lib/format";
import { Badge, Field, lineStyle, Msg, rowBtn, useRun } from "../../purchases/ui";
import Link from "next/link";
import { closeRequest, issueStock, sendRequest } from "./actions";

type Ing = { id: string; name: string; unit: string };
type ReqLine = { ingredient_id: string; name: string; unit: string; qty: number; issued: number };
export type ReqRow = { id: string; number: string; department: string; status: string; note: string | null; rejectReason: string | null; createdAt: string; lines: ReqLine[] };
type IssueRow = { id: string; number: string; department: string; issuedOn: string; value: number; note: string | null };

const DEPARTMENTS = ["Kitchen", "Bar", "Bakery", "Housekeeping", "Other"];
const STATUS: Record<string, { label: string; bg: string; fg: string }> = {
  requested: { label: "Waiting", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  part_issued: { label: "Part issued", bg: "var(--color-warn-soft)", fg: "var(--color-warn)" },
  issued: { label: "Issued", bg: "var(--color-ok-soft)", fg: "var(--color-ok)" },
  rejected: { label: "Turned down", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
  cancelled: { label: "Withdrawn", bg: "var(--color-bad-soft)", fg: "var(--color-bad)" },
};
const num = (s: string) => {
  const n = Number(s.trim());
  return Number.isFinite(n) && n > 0 ? n : 0;
};

export function RequestsBoard({ canManage, canBackdate, currency, ingredients, requests, issues, departments }: { departments?: string[]; canManage: boolean; canBackdate?: boolean; currency: string; ingredients: Ing[]; requests: ReqRow[]; issues: IssueRow[] }) {
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const [mode, setMode] = useState<"none" | "ask" | "direct">("none");
  const m = (n: number) => money(n, currency);
  const done = (text: string) => {
    setMode("none");
    setNote({ ok: true, text });
  };
  return (
    <div className="space-y-5">
      <p className="rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
        Ingredients used in dishes already come off stock when the dish is billed. Issue them here only for what is used outside dishes, or they are counted twice.
      </p>
      <div className="flex flex-wrap gap-2">
        <button type="button" className="btn btn-primary px-4 text-sm" onClick={() => setMode(mode === "ask" ? "none" : "ask")}>
          Ask for stock
        </button>
        {canManage && (
          <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={() => setMode(mode === "direct" ? "none" : "direct")}>
            Issue without a request
          </button>
        )}
      </div>
      <Msg msg={note} />
      {mode === "ask" && <LinesForm title="Ask for stock" action="Send request" ingredients={ingredients} askDepartment departments={departments} onDone={done} onClose={() => setMode("none")} />}
      {mode === "direct" && canManage && <LinesForm title="Issue stock" action="Issue stock" ingredients={ingredients} askDepartment departments={departments} direct canBackdate={canBackdate} onDone={done} onClose={() => setMode("none")} />}

      <section>
        <h2 className="mb-2 text-sm font-bold">Requests</h2>
        <div className="card">
          {requests.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              No requests yet.
            </p>
          ) : (
            <ul>
              {requests.map((r, i) => (
                <RequestItem key={r.id} r={r} first={i === 0} canManage={canManage} onDone={done} />
              ))}
            </ul>
          )}
        </div>
      </section>

      <section>
        <h2 className="mb-2 text-sm font-bold">Recently issued</h2>
        <div className="card">
          {issues.length === 0 ? (
            <p className="px-4 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
              Nothing issued yet.
            </p>
          ) : (
            <ul>
              {issues.map((x, i) => (
                <li key={x.id} className="flex items-center justify-between gap-3 px-4 py-2.5 text-sm" style={i > 0 ? { borderTop: "1px solid var(--color-line)" } : undefined}>
                  <span>
                    <b>{x.number}</b> · {x.department} · {x.issuedOn}
                    {x.note ? <span style={{ color: "var(--color-ink-3)" }}> · {x.note}</span> : null}
                  </span>
                  <span className="flex items-center gap-3">
                    <Link href={`/stock/note/issue/${x.id}`} className="text-xs font-semibold" style={{ color: "var(--color-brand)" }}>
                      Print
                    </Link>
                    <span className="font-semibold tabular-nums">{m(x.value)}</span>
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
}

/** One request with what can be done to it. */
function RequestItem({ r, first, canManage, onDone }: { r: ReqRow; first: boolean; canManage: boolean; onDone: (t: string) => void }) {
  const run = useRun();
  const [open, setOpen] = useState<"none" | "issue" | "reject">("none");
  const [qty, setQty] = useState<Record<string, string>>(() => Object.fromEntries(r.lines.map((l) => [l.ingredient_id, String(Math.max(0, Math.round((l.qty - l.issued) * 1000) / 1000))])));
  const [reason, setReason] = useState("");
  const ref = useRef<string>(crypto.randomUUID());
  const st = STATUS[r.status] ?? STATUS.requested;
  const openReq = r.status === "requested" || r.status === "part_issued";

  function issue() {
    const lines = r.lines.map((l) => ({ ingredient_id: l.ingredient_id, qty: num(qty[l.ingredient_id] ?? "") })).filter((l) => l.qty > 0);
    if (lines.length === 0) return run.setMsg({ ok: false, text: "Enter how much is being issued." });
    run.run(
      () => issueStock({ requestId: r.id, department: r.department, lines, note: "", clientRef: ref.current }),
      (x) => {
        ref.current = crypto.randomUUID();
        setOpen("none");
        onDone(x.message);
        return x.message;
      },
    );
  }
  function close(action: "reject" | "cancel" | "close") {
    run.run(
      () => closeRequest(r.id, action, reason),
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
          <span className="font-semibold">{r.number}</span> <Badge label={st.label} bg={st.bg} fg={st.fg} />{" "}
          <Link href={`/stock/note/request/${r.id}`} className="text-xs font-semibold" style={{ color: "var(--color-brand)" }}>
            Print
          </Link>
          <div className="text-sm" style={{ color: "var(--color-ink-2)" }}>
            For {r.department} · {r.createdAt.slice(0, 10)}
            {r.note ? ` · ${r.note}` : ""}
          </div>
          {r.rejectReason && (
            <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
              Reason: {r.rejectReason}
            </div>
          )}
        </div>
      </div>
      <ul className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
        {r.lines.map((l) => (
          <li key={l.ingredient_id}>
            {l.name}: {l.qty} {l.unit}
            {l.issued > 0 ? ` (issued ${l.issued})` : ""}
          </li>
        ))}
      </ul>
      {openReq && open === "none" && (
        <div className="mt-2 flex flex-wrap gap-2">
          {canManage && (
            <button type="button" className={rowBtn} style={{ borderColor: "var(--color-brand)", color: "var(--color-brand)" }} onClick={() => setOpen("issue")} disabled={run.pending}>
              Issue
            </button>
          )}
          {canManage && (
            <button type="button" className={rowBtn} style={{ ...lineStyle, color: "var(--color-bad)" }} onClick={() => setOpen("reject")} disabled={run.pending}>
              Turn down
            </button>
          )}
          {canManage && r.status === "part_issued" && (
            <button type="button" className={rowBtn} style={lineStyle} onClick={() => close("close")} disabled={run.pending}>
              No more coming
            </button>
          )}
          {r.status === "requested" && (
            <button type="button" className={rowBtn} style={lineStyle} onClick={() => close("cancel")} disabled={run.pending}>
              Withdraw
            </button>
          )}
        </div>
      )}
      {open === "issue" && (
        <div className="mt-3 rounded-2xl border p-3" style={lineStyle}>
          <ul className="space-y-2">
            {r.lines.filter((l) => l.qty - l.issued > 0).map((l) => (
              <li key={l.ingredient_id} className="grid grid-cols-[minmax(0,1fr)_110px] items-center gap-2 text-sm">
                <span>
                  {l.name}
                  <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
                    still to issue {Math.round((l.qty - l.issued) * 1000) / 1000} {l.unit}
                  </span>
                </span>
                <input className="field h-10 text-sm" inputMode="decimal" aria-label={`Quantity of ${l.name} to issue`} value={qty[l.ingredient_id] ?? ""} onChange={(e) => setQty({ ...qty, [l.ingredient_id]: e.target.value })} disabled={run.pending} />
              </li>
            ))}
          </ul>
          <div className="mt-2">
            <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
          </div>
          <div className="mt-3 flex gap-2">
            <button type="button" className="btn btn-primary px-4 text-sm" onClick={issue} disabled={run.pending}>
              {run.pending ? "Saving…" : "Issue stock"}
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
            <input className="field h-10 text-sm" placeholder="e.g. not in stock, order tomorrow" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} disabled={run.pending} />
          </Field>
          <div className="mt-2">
            <Msg msg={run.msg && !run.msg.ok ? run.msg : null} />
          </div>
          <div className="mt-3 flex gap-2">
            <button type="button" className="btn px-4 text-sm" style={{ background: "var(--color-bad)", color: "#fff" }} onClick={() => close("reject")} disabled={run.pending || reason.trim().length < 3}>
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

/** The shared "pick ingredients and quantities" form: a request, or an issue without one. */
function LinesForm({ title, action, ingredients, askDepartment, departments, direct, canBackdate, onDone, onClose }: { departments?: string[]; title: string; action: string; ingredients: Ing[]; askDepartment: boolean; direct?: boolean; canBackdate?: boolean; onDone: (t: string) => void; onClose: () => void }) {
  const run = useRun();
  const [dept, setDept] = useState(departments && departments.length > 0 && !departments.some((d) => d.toLowerCase() === "kitchen") ? departments[0] : "Kitchen");
  const [rows, setRows] = useState<{ id: string; qty: string }[]>([{ id: "", qty: "" }, { id: "", qty: "" }, { id: "", qty: "" }]);
  const [note, setNote] = useState("");
  const [issueDate, setIssueDate] = useState("");
  const ref = useRef<string>(crypto.randomUUID());
  const set = (i: number, p: Partial<{ id: string; qty: string }>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...p } : r)));

  function save() {
    const lines = rows.filter((r) => r.id && num(r.qty) > 0).map((r) => ({ ingredient_id: r.id, qty: num(r.qty) }));
    if (rows.some((r) => (r.id && !num(r.qty)) || (!r.id && r.qty.trim() !== ""))) return run.setMsg({ ok: false, text: "Finish or clear every line first." });
    if (lines.length === 0) return run.setMsg({ ok: false, text: "Add at least one ingredient with a quantity." });
    if (new Set(lines.map((l) => l.ingredient_id)).size !== lines.length) return run.setMsg({ ok: false, text: "An ingredient is on the list twice. Put it on one line." });
    if (dept.trim().length < 2) return run.setMsg({ ok: false, text: "Say who it is for." });
    run.run(
      () => (direct ? issueStock({ requestId: null, department: dept, lines, note, clientRef: ref.current, issueDate: canBackdate ? issueDate : "" }) : sendRequest({ department: dept, lines, note, clientRef: ref.current })),
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
      <h2 className="text-sm font-bold">{title}</h2>
      {direct && canBackdate && (
        <Field label="Issue date" hint="(leave empty for today)" className="mt-2">
          <input type="date" className="field h-10 text-sm" value={issueDate} onChange={(e) => setIssueDate(e.target.value)} disabled={run.pending} />
        </Field>
      )}
      {askDepartment && (
        <Field label="For" className="mt-2">
          <input className="field h-10 text-sm" list="mr-departments" value={dept} onChange={(e) => setDept(e.target.value)} maxLength={40} disabled={run.pending} />
          <datalist id="mr-departments">
            {(departments && departments.length > 0 ? departments : DEPARTMENTS).map((d) => (
              <option key={d} value={d} />
            ))}
          </datalist>
        </Field>
      )}
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
          {run.pending ? "Saving…" : action}
        </button>
        <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={run.pending}>
          Close
        </button>
      </div>
    </section>
  );
}
