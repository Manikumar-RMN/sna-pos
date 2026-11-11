"use client";

import { useState } from "react";
import { amendReceipt } from "./actions";
import { Field, Msg, lineStyle, useRun } from "./ui";

/** Fix a wrongly typed supplier bill number, bill date or due date. Stock and money stay as they are. */
export function AmendForm({
  receipt,
  today,
  onDone,
  onClose,
}: {
  receipt: { id: string; number: string; bill_no: string | null; bill_date: string | null; due_on: string | null };
  today: string;
  onDone: (text: string) => void;
  onClose: () => void;
}) {
  const { pending, msg, run } = useRun();
  const [billNo, setBillNo] = useState(receipt.bill_no ?? "");
  const [billDate, setBillDate] = useState(receipt.bill_date ?? "");
  const [dueOn, setDueOn] = useState(receipt.due_on ?? "");
  const [reason, setReason] = useState("");

  function save() {
    run(() => amendReceipt({ receiptId: receipt.id, billNo, billDate, dueOn, reason }), (r) => {
      onDone(r.message ?? "Corrected.");
      return r.message;
    });
  }

  return (
    <div className="mt-2 rounded-xl border p-3" style={lineStyle}>
      <div className="text-sm font-bold">Correct details on {receipt.number}</div>
      <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
        Changes the bill number and dates only. The goods, cost and amount owed stay as they are. The old values are kept in the audit trail.
      </p>
      <div className="mt-2 grid gap-3 sm:grid-cols-3">
        <Field label="Supplier's bill number">
          <input className="field h-10 text-sm" value={billNo} onChange={(e) => setBillNo(e.target.value)} maxLength={60} disabled={pending} />
        </Field>
        <Field label="Bill date">
          <input className="field h-10 text-sm" type="date" max={today} value={billDate} onChange={(e) => setBillDate(e.target.value)} disabled={pending} />
        </Field>
        <Field label="Due date">
          <input className="field h-10 text-sm" type="date" value={dueOn} onChange={(e) => setDueOn(e.target.value)} disabled={pending} />
        </Field>
      </div>
      <Field label="Why is this being corrected?" className="mt-2 max-w-md">
        <input className="field h-10 text-sm" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} placeholder="e.g. typed the wrong bill number" disabled={pending} />
      </Field>
      <div className="mt-2 space-y-2">
        <Msg msg={msg && !msg.ok ? msg : null} />
        <div className="flex flex-wrap gap-2">
          <button type="button" className="btn btn-primary px-4 text-sm" onClick={save} disabled={pending}>
            {pending ? "Saving…" : "Save correction"}
          </button>
          <button type="button" className="btn border px-4 text-sm" style={lineStyle} onClick={onClose} disabled={pending}>
            Close
          </button>
        </div>
      </div>
    </div>
  );
}
