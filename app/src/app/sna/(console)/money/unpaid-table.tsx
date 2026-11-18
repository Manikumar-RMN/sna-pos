"use client";

import Link from "next/link";
import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { setSalePaid, setSaleDue } from "../actions";
import { labelOf, SALE_KINDS, shortDate, toneStyle } from "../crm";

export type UnpaidRow = {
  id: string;
  restaurant_id: string;
  trading_name: string;
  client_code: string;
  sale_date: string;
  kind: string;
  description: string;
  amount: number;
  currency: string;
  invoice_no: string | null;
  due_on: string | null;
  days_since: number;
  days_overdue: number | null;
};

export function UnpaidTable({ rows, today, canEdit }: { rows: UnpaidRow[]; today: string; canEdit: boolean }) {
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const run = (p: Promise<{ ok: true; message: string } | { ok: false; error: string }>) =>
    start(async () => {
      const r = await p;
      setMsg(r.ok ? { ok: true, text: r.message } : { ok: false, text: r.error });
    });

  return (
    <div className="space-y-3">
      {msg && (
        <div role={msg.ok ? "status" : "alert"} className="card p-3 text-sm font-semibold" style={{ color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </div>
      )}
      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
              <th className="px-3 py-2.5">Client</th>
              <th className="px-3 py-2.5">What was sold</th>
              <th className="px-3 py-2.5">Sold on</th>
              <th className="px-3 py-2.5">Due</th>
              <th className="px-3 py-2.5 text-right">Amount</th>
              {canEdit && <th className="px-3 py-2.5" />}
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} className="border-t align-top" style={{ borderColor: "var(--color-line)" }}>
                <td className="px-3 py-3">
                  <Link href={`/sna/r/${r.restaurant_id}?tab=sales`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                    {r.trading_name}
                  </Link>
                  <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                    Code {r.client_code}
                  </div>
                </td>
                <td className="px-3 py-3">
                  <div>{r.description}</div>
                  <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                    {labelOf(SALE_KINDS, r.kind)}
                    {r.invoice_no ? ` · invoice ${r.invoice_no}` : ""}
                  </div>
                </td>
                <td className="whitespace-nowrap px-3 py-3">
                  {shortDate(r.sale_date)}
                  <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                    {r.days_since === 0 ? "today" : `${r.days_since} ${r.days_since === 1 ? "day" : "days"} ago`}
                  </div>
                </td>
                <td className="whitespace-nowrap px-3 py-3">
                  {canEdit ? (
                    <input
                      type="date"
                      className="field h-9 w-40"
                      aria-label={`Due date for ${r.trading_name}, ${r.description}`}
                      defaultValue={r.due_on ?? ""}
                      min={r.sale_date}
                      disabled={pending}
                      onChange={(e) => e.target.value !== (r.due_on ?? "") && run(setSaleDue(r.id, e.target.value))}
                    />
                  ) : (
                    <span>{r.due_on ? shortDate(r.due_on) : <span style={{ color: "var(--color-ink-3)" }}>Not set</span>}</span>
                  )}
                  {r.days_overdue !== null && (
                    <div className="mt-1">
                      <span className="rounded-full px-2 py-0.5 text-[11px] font-bold" style={toneStyle.bad}>
                        {r.days_overdue} {r.days_overdue === 1 ? "day" : "days"} overdue
                      </span>
                    </div>
                  )}
                </td>
                <td className="whitespace-nowrap px-3 py-3 text-right font-semibold tabular-nums">{money(Number(r.amount), r.currency)}</td>
                {canEdit && (
                  <td className="whitespace-nowrap px-3 py-3 text-right">
                    <button
                      type="button"
                      className="rounded-lg border px-3 py-1.5 text-xs font-bold"
                      style={{ borderColor: "var(--color-line)" }}
                      disabled={pending}
                      onClick={() => run(setSalePaid(r.restaurant_id, r.id, today))}
                    >
                      Mark paid today
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
