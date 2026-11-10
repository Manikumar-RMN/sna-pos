"use client";

import { useState } from "react";
import { Field, Msg, useRun } from "../ui";
import { savePurchaseRules } from "./actions";

type Rules = { direct: boolean; rateCheck: "off" | "warn" | "block"; excess: boolean; needsRequisition: boolean; backdateDays: number; blockExpired: boolean };

export function RulesBoard({ canEdit, initial }: { canEdit: boolean; initial: Rules }) {
  const { pending, msg, run } = useRun();
  const [r, setR] = useState<Rules>(initial);
  const [days, setDays] = useState(String(initial.backdateDays));
  const upd = (p: Partial<Rules>) => setR((x) => ({ ...x, ...p }));
  const d = canEdit && !pending;
  const Row = ({ title, text, checked, on }: { title: string; text: string; checked: boolean; on: (v: boolean) => void }) => (
    <label className="flex items-start gap-3 py-3 text-sm">
      <input type="checkbox" className="mt-0.5 h-5 w-5" checked={checked} onChange={(e) => on(e.target.checked)} disabled={!d} />
      <span>
        <b>{title}</b>
        <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
          {text}
        </span>
      </span>
    </label>
  );
  return (
    <div className="card divide-y px-4" style={{ borderColor: "var(--color-line)" }}>
      <Row title="Allow receiving goods without an order" text="Untick to make staff choose a purchase order for every delivery." checked={r.direct} on={(v) => upd({ direct: v })} />
      <Row title="Allow receiving more than was ordered" text="Untick to stop a delivery from going over what is still due on its order." checked={r.excess} on={(v) => upd({ excess: v })} />
      <Row title="Orders only from approved requisitions" text="Tick to stop staff writing a new order directly; they must raise a requisition first." checked={r.needsRequisition} on={(v) => upd({ needsRequisition: v })} />
      <Row title="Do not issue stock that has expired" text="Tick to stop issuing an item to a department while some of it has passed its best-before date. Write the expired stock off first. Needs expiry dates on the deliveries." checked={r.blockExpired} on={(v) => upd({ blockExpired: v })} />
      <div className="py-3">
        <Field label="Check the rate against the order or the agreed rate" hint="(before tax)">
          <select className="field h-10 text-sm" value={r.rateCheck} onChange={(e) => upd({ rateCheck: e.target.value as Rules["rateCheck"] })} disabled={!d}>
            <option value="off">Off: any rate is accepted</option>
            <option value="warn">Warn: the screen shows a warning but saves</option>
            <option value="block">Block: a different rate cannot be saved</option>
          </select>
        </Field>
      </div>
      <div className="py-3">
        <Field label="How many days back may an earlier date go" hint="(for people with the earlier-date right)">
          <input className="field h-10 w-28 text-sm" inputMode="numeric" value={days} onChange={(e) => setDays(e.target.value)} disabled={!d} />
        </Field>
      </div>
      <div className="py-4">
        <Msg msg={msg} />
        {canEdit ? (
          <button type="button" className="btn btn-primary px-4 text-sm" disabled={pending} onClick={() => run(() => savePurchaseRules({ ...r, backdateDays: Number(days.trim()) }))}>
            {pending ? "Saving…" : "Save rules"}
          </button>
        ) : (
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Only the owner can change these.
          </p>
        )}
      </div>
    </div>
  );
}
