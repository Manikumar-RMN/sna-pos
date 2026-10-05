"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { closeShift, openShift, recordCash } from "./actions";
import { paidLaterNote, voidedAfterCloseNote } from "./figures";

export type ShiftFigures = {
  shift_id: string;
  opened_at: string;
  opened_by: string | null;
  bills: number;
  unpaid?: number;
  /** Still to collect on the unpaid bills. Older reports do not have it. */
  unpaid_amount?: number;
  /** A closed shift only: bills voided after it closed. Older reports do not have them. */
  voided_after_close?: number;
  voided_after_close_value?: number;
  /** A closed shift only: bills unpaid when it closed that were paid in a later shift. Older reports do not have them. */
  paid_later?: number;
  paid_later_value?: number;
  sales?: number;
  opening_float?: number;
  cash_sales?: number;
  cash_refunds?: number;
  cash_in?: number;
  cash_out?: number;
  expected_cash?: number;
  by_method?: { method: string; bills: number; amount: number }[];
};

function Msg({ error, notice }: { error: string | null; notice: string | null }) {
  if (error)
    return (
      <p className="mt-3 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
        {error}
      </p>
    );
  if (notice)
    return (
      <p className="mt-3 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}>
        {notice}
      </p>
    );
  return null;
}

/** "Open shift" box: used on the Shift screen and on the billing screen. */
export function OpenShiftForm({ canOpen, compact = false }: { canOpen: boolean; compact?: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [float, setFloat] = useState("");
  const [error, setError] = useState<string | null>(null);

  if (!canOpen) {
    return (
      <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        No shift is open. Ask the cashier or manager to open the shift before billing.
      </div>
    );
  }

  return (
    <div className="card p-5">
      <h2 className="text-base font-bold">Open the shift</h2>
      <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
        {compact
          ? "Billing starts once a shift is open. Count the cash in the drawer and enter it."
          : "Count the cash already in the drawer (the float) and enter it. Enter 0 if the drawer is empty."}
      </p>
      <div className="mt-4 flex gap-2">
        <input
          className="field flex-1"
          inputMode="decimal"
          placeholder="Cash in drawer, e.g. 500"
          value={float}
          onChange={(e) => setFloat(e.target.value)}
        />
        <button
          className="btn btn-primary"
          disabled={pending || float === ""}
          onClick={() => {
            setError(null);
            start(async () => {
              const res = await openShift(Number(float));
              if (!res.ok) return setError(res.error);
              router.refresh();
            });
          }}
        >
          {pending ? "Opening…" : "Open shift"}
        </button>
      </div>
      <Msg error={error} notice={null} />
    </div>
  );
}

export function ShiftPanel({
  figures,
  currency,
  canMoveCash,
  canClose,
  canSeeMoney,
}: {
  figures: ShiftFigures;
  currency: string;
  canMoveCash: boolean;
  canClose: boolean;
  canSeeMoney: boolean;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const [dir, setDir] = useState<"in" | "out">("out");
  const [amt, setAmt] = useState("");
  const [reason, setReason] = useState("");
  const [counted, setCounted] = useState("");
  const [notes, setNotes] = useState("");
  const [confirmClose, setConfirmClose] = useState(false);

  const f = figures;
  const c = currency;
  const unpaidAmount = Number(f.unpaid_amount ?? 0);
  const lateVoids = voidedAfterCloseNote(f, c);
  const paidLater = paidLaterNote(f, c);

  return (
    <div className="space-y-4">
      {canSeeMoney && (
        <div className="grid gap-3 sm:grid-cols-4">
          <Tile label="Bills this shift" value={String(f.bills)} />
          <Tile label="Sales" value={money(f.sales, c)} />
          <Tile label="Cash sales" value={money(f.cash_sales, c)} />
          <Tile label="Expected in drawer" value={money(f.expected_cash, c)} strong />
        </div>
      )}

      {canSeeMoney && (
        <div className="card p-4 text-sm">
          <h2 className="mb-2 font-bold">Drawer</h2>
          <dl className="space-y-1">
            <Line label="Opening float" value={money(f.opening_float, c)} />
            <Line label="+ Cash sales" value={money(f.cash_sales, c)} />
            <Line label="− Cash refunds" value={money(f.cash_refunds, c)} />
            <Line label="+ Cash in" value={money(f.cash_in, c)} />
            <Line label="− Cash out" value={money(f.cash_out, c)} />
            <div className="border-t pt-1" style={{ borderColor: "var(--color-line)" }}>
              <Line label="Expected cash" value={money(f.expected_cash, c)} bold />
            </div>
          </dl>
          {(f.by_method ?? []).length > 0 && (
            <>
              <h3 className="mb-1 mt-4 text-xs font-bold uppercase" style={{ color: "var(--color-ink-3)" }}>
                By payment method
              </h3>
              <dl className="space-y-1">
                {(f.by_method ?? []).map((m) => (
                  <Line key={m.method} label={`${m.method} (${m.bills})`} value={money(m.amount, c)} />
                ))}
              </dl>
            </>
          )}
          {(f.unpaid ?? 0) > 0 && (
            <p className="mt-3 rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              {f.unpaid} unpaid bill{f.unpaid === 1 ? "" : "s"} in this shift.{unpaidAmount > 0 ? ` Not yet paid: ${money(unpaidAmount, c)}.` : ""} Collect
              payment on the Bills screen before closing.
            </p>
          )}
          {lateVoids && (
            <p className="mt-3 rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              {lateVoids}
            </p>
          )}
          {paidLater && (
            <p className="mt-3 rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              {paidLater}
            </p>
          )}
        </div>
      )}

      {canMoveCash && (
        <div className="card p-4">
          <h2 className="text-sm font-bold">Cash in / cash out</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Money added to or taken from the drawer that is not a bill — change brought in, milk bought, and so on.
          </p>
          <div className="mt-3 flex overflow-hidden rounded-lg border" style={{ borderColor: "var(--color-line)", width: "fit-content" }}>
            {(["out", "in"] as const).map((d) => (
              <button
                key={d}
                onClick={() => setDir(d)}
                className="px-4 py-2 text-xs font-semibold"
                style={{ background: dir === d ? "var(--color-brand)" : "transparent", color: dir === d ? "#fff" : "var(--color-ink-2)" }}
              >
                {d === "out" ? "Cash out" : "Cash in"}
              </button>
            ))}
          </div>
          <div className="mt-2 grid gap-2 sm:grid-cols-[140px_1fr_auto]">
            <input className="field h-11 text-sm" inputMode="decimal" placeholder="Amount" value={amt} onChange={(e) => setAmt(e.target.value)} />
            <input className="field h-11 text-sm" placeholder="Reason" value={reason} onChange={(e) => setReason(e.target.value)} />
            <button
              className="btn border text-sm"
              style={{ borderColor: "var(--color-line)" }}
              disabled={pending || !amt || reason.trim().length < 2}
              onClick={() => {
                setError(null);
                setNotice(null);
                start(async () => {
                  const res = await recordCash({ direction: dir, amount: Number(amt), reason });
                  if (!res.ok) return setError(res.error);
                  setNotice(res.message ?? "Saved.");
                  setAmt("");
                  setReason("");
                  router.refresh();
                });
              }}
            >
              Save
            </button>
          </div>
        </div>
      )}

      {canClose && (
        <div className="card p-4">
          <h2 className="text-sm font-bold">Close shift (day close)</h2>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Count every note and coin in the drawer and enter the total. SNA POS compares it with the expected cash and records any difference.
          </p>
          <div className="mt-3 grid gap-2 sm:grid-cols-[160px_1fr]">
            <input className="field h-11 text-sm" inputMode="decimal" placeholder="Cash counted" value={counted} onChange={(e) => setCounted(e.target.value)} />
            <input className="field h-11 text-sm" placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} />
          </div>
          {confirmClose ? (
            <div className="mt-3 flex gap-2">
              <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirmClose(false)}>
                Cancel
              </button>
              <button
                className="btn btn-primary flex-1 text-sm"
                disabled={pending}
                onClick={() => {
                  setError(null);
                  setNotice(null);
                  start(async () => {
                    const res = await closeShift(Number(counted), notes);
                    setConfirmClose(false);
                    if (!res.ok) return setError(res.error);
                    setNotice(res.message ?? "Shift closed.");
                    router.refresh();
                  });
                }}
              >
                {pending ? "Closing…" : `Close with ${money(Number(counted) || 0, c)} counted`}
              </button>
            </div>
          ) : (
            <button className="btn btn-primary mt-3 w-full" disabled={counted === ""} onClick={() => setConfirmClose(true)}>
              Close shift…
            </button>
          )}
        </div>
      )}

      <Msg error={error} notice={notice} />
    </div>
  );
}

function Tile({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className="card p-3">
      <div className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
        {label}
      </div>
      <div className="mt-1 text-lg font-bold tabular-nums" style={strong ? { color: "var(--color-brand-strong)" } : undefined}>
        {value}
      </div>
    </div>
  );
}

function Line({ label, value, bold }: { label: string; value: string; bold?: boolean }) {
  return (
    <div className={`flex justify-between ${bold ? "font-bold" : ""}`}>
      <dt style={bold ? undefined : { color: "var(--color-ink-2)" }}>{label}</dt>
      <dd className="tabular-nums">{value}</dd>
    </div>
  );
}
