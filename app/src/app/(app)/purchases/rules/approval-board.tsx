"use client";

import { useState } from "react";
import { Field, Msg, lineStyle, useRun } from "../ui";
import { saveApprovalLevels } from "./actions";

export type Person = { id: string; name: string };
type Row = { level: number; minAmount: string; approverId: string };

/** Up to six approval levels for purchase orders. Each level has a "from amount" and one person who approves it. */
export function ApprovalBoard({ canEdit, people, initial, blockSelf, currency }: { canEdit: boolean; people: Person[]; initial: { level: number; minAmount: number; approverId: string }[]; blockSelf: boolean; currency: string }) {
  const { pending, msg, setMsg, run } = useRun();
  const [rows, setRows] = useState<Row[]>(initial.map((l) => ({ level: l.level, minAmount: String(l.minAmount), approverId: l.approverId })));
  const [block, setBlock] = useState(blockSelf);
  const d = canEdit && !pending;
  const nextLevel = [1, 2, 3, 4, 5, 6].find((n) => !rows.some((r) => r.level === n));
  const set = (level: number, p: Partial<Row>) => setRows((x) => x.map((r) => (r.level === level ? { ...r, ...p } : r)));

  function save() {
    const levels: { level: number; minAmount: number; approverId: string }[] = [];
    for (const r of rows) {
      const n = Number(r.minAmount.trim());
      if (r.minAmount.trim() === "" || !Number.isFinite(n) || n < 0) return setMsg({ ok: false, text: `Enter the starting amount for level ${r.level}.` });
      levels.push({ level: r.level, minAmount: n, approverId: r.approverId });
    }
    run(() => saveApprovalLevels({ levels, blockSelf: block }));
  }

  return (
    <section className="mt-6">
      <h2 className="text-sm font-bold">Approving purchase orders</h2>
      <p className="mt-1 mb-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Leave empty and every order can be sent. With levels, an order whose total reaches a level&rsquo;s amount must be approved by that level&rsquo;s person, and by every level before it, before it can be sent. Changing an order asks for its approvals again. Amounts are in {currency}.
      </p>
      <div className="card px-4">
        {rows.length === 0 && (
          <p className="py-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
            No approval is needed.
          </p>
        )}
        {rows.map((r) => (
          <div key={r.level} className="flex flex-wrap items-end gap-3 py-3" style={{ borderTop: "1px solid var(--color-line)" }}>
            <div className="w-16 pb-2 text-sm font-bold">Level {r.level}</div>
            <Field label="From order total">
              <input className="field h-10 w-32 text-sm" inputMode="decimal" value={r.minAmount} onChange={(e) => set(r.level, { minAmount: e.target.value })} disabled={!d} aria-label={`Level ${r.level} from amount`} />
            </Field>
            <Field label="Approved by">
              <select className="field h-10 text-sm" value={r.approverId} onChange={(e) => set(r.level, { approverId: e.target.value })} disabled={!d} aria-label={`Level ${r.level} approver`}>
                {people.map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name}
                  </option>
                ))}
              </select>
            </Field>
            {canEdit && (
              <button type="button" className="inline-flex min-h-10 items-center rounded-xl border px-3 text-sm font-semibold" style={{ ...lineStyle, color: "var(--color-bad)" }} onClick={() => setRows((x) => x.filter((q) => q.level !== r.level))} disabled={!d}>
                Remove
              </button>
            )}
          </div>
        ))}
        {canEdit && nextLevel && people.length > 0 && (
          <div className="py-3" style={{ borderTop: "1px solid var(--color-line)" }}>
            <button type="button" className="inline-flex min-h-10 items-center rounded-xl border px-3 text-sm font-semibold" style={lineStyle} onClick={() => setRows((x) => [...x, { level: nextLevel, minAmount: "", approverId: people[0].id }].sort((a, b) => a.level - b.level))} disabled={!d}>
              + Add level {nextLevel}
            </button>
          </div>
        )}
        <label className="flex items-start gap-3 py-3 text-sm" style={{ borderTop: "1px solid var(--color-line)" }}>
          <input type="checkbox" className="mt-0.5 h-5 w-5" checked={block} onChange={(e) => setBlock(e.target.checked)} disabled={!d} />
          <span>
            <b>The person who wrote an order cannot approve it</b>
            <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
              Tick this once there is more than one person who can approve.
            </span>
          </span>
        </label>
        <div className="py-4" style={{ borderTop: "1px solid var(--color-line)" }}>
          <Msg msg={msg} />
          {canEdit ? (
            <button type="button" className="btn btn-primary px-4 text-sm" disabled={pending} onClick={save}>
              {pending ? "Saving…" : "Save approval levels"}
            </button>
          ) : (
            <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
              Only the owner can change these.
            </p>
          )}
        </div>
      </div>
    </section>
  );
}
