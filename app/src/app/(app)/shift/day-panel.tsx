"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useState, useTransition } from "react";
import { readQueue } from "@/lib/offline";
import { money } from "@/lib/format";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { closeDay, reopenDay } from "./actions";

export type DayStatus = {
  open_day: { id: string; business_date: string; opened_at: string; bills: number } | null;
  unpaid: { id: string; bill_number: string; total: number; balance: number }[];
  shift_open: boolean;
  recent: { id: string; business_date: string; status: string; closed_at: string | null; total: number | null }[];
  can_close: boolean;
  can_reopen: boolean;
  /** Shifts switched on in Settings → Day and sessions. Off: one automatic drawer per day, counted at day close. */
  shifts_enabled?: boolean;
  expected_cash?: number | null;
  /** Kitchen tickets still new or being prepared (a warning only; it does not block closing). */
  pending_kots?: number;
};

function niceDate(d: string) {
  return new Date(`${d}T00:00:00`).toLocaleDateString("en-IN", { weekday: "short", day: "numeric", month: "short", year: "numeric" });
}

export function DayPanel({ status, currency, canAsk }: { status: DayStatus; currency: string; canAsk: boolean }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [notes, setNotes] = useState("");
  const [reason, setReason] = useState("");
  const [counted, setCounted] = useState("");
  const [confirm, setConfirm] = useState<null | "close" | "reopen">(null);
  const [approval, setApproval] = useState<null | { permission: string; retry: () => void }>(null);
  const d = status.open_day;
  const lastClosed = status.recent.find((x) => x.status === "closed");
  const [waiting, setWaiting] = useState(0);
  useEffect(() => setWaiting(readQueue().length), []);
  const blocked = status.shift_open || status.unpaid.length > 0 || waiting > 0;
  const unpaidAmount = status.unpaid.reduce((sum, u) => sum + Number(u.balance ?? 0), 0);

  function run(fn: () => Promise<{ ok: boolean; error?: string; message?: string }>) {
    setMsg(null);
    start(async () => {
      const res = await fn();
      if (!res.ok) {
        const need = neededRight(res.error);
        if (need) setApproval({ permission: need, retry: () => run(fn) });
        setMsg({ ok: false, text: cleanMessage(res.error ?? "Something went wrong.") });
        return;
      }
      setMsg({ ok: true, text: res.message ?? "Done." });
      setConfirm(null);
      setNotes("");
      setReason("");
      router.refresh();
    });
  }

  return (
    <section className="card mt-6 p-5">
      {approval && (
        <ApprovalPrompt
          permission={approval.permission}
          onCancel={() => setApproval(null)}
          onApproved={() => {
            const r = approval.retry;
            setApproval(null);
            r();
          }}
        />
      )}
      <h2 className="text-base font-bold">Business day</h2>
      {d ? (
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Open day: <b>{niceDate(d.business_date)}</b> · {d.bills} bill{d.bills === 1 ? "" : "s"}
        </p>
      ) : (
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-2)" }}>
          No day is open. The next bill opens a new day.
        </p>
      )}

      {d && (status.can_close || canAsk) && (
        <div className="mt-4">
          {status.shift_open && (
            <p className="mb-2 rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              Close the shift above (count the cash) before closing the day.
            </p>
          )}
          {waiting > 0 && (
            <p className="mb-2 rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              {waiting} bill{waiting === 1 ? " made" : "s made"} offline on this device {waiting === 1 ? "has" : "have"} not been sent yet. Wait for the internet, then close the day.
            </p>
          )}
          {(status.pending_kots ?? 0) > 0 && (
            <p className="mb-2 rounded-lg px-3 py-2 text-xs font-semibold" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
              {status.pending_kots} kitchen ticket{status.pending_kots === 1 ? " is" : "s are"} still pending. Check the Kitchen screen before you close the day.
            </p>
          )}
          {status.unpaid.length > 0 && (
            <div className="mb-2 rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-warn-soft)" }}>
              <div className="font-semibold" style={{ color: "var(--color-warn)" }}>
                {status.unpaid.length} bill{status.unpaid.length === 1 ? " is" : "s are"} not paid.{unpaidAmount > 0 ? ` Not yet paid: ${money(unpaidAmount, currency)}.` : ""} Settle or void{" "}
                {status.unpaid.length === 1 ? "it" : "them"} first:
              </div>
              <ul className="mt-1 flex flex-wrap gap-x-3 gap-y-1">
                {status.unpaid.map((u) => (
                  <li key={u.id}>
                    <Link href={`/bills/${u.id}`} className="font-semibold underline" style={{ color: "var(--color-brand-strong)" }}>
                      {u.bill_number}
                    </Link>{" "}
                    {money(u.balance, currency)}
                  </li>
                ))}
              </ul>
            </div>
          )}
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Closing freezes the day: its bills can no longer be voided or changed, and the end-of-day report is saved. Refunds
            after that are made as credit notes dated the day they are given.
          </p>
          {!status.shifts_enabled && status.expected_cash != null && (
            <div className="mt-3 rounded-lg p-3 text-sm" style={{ background: "var(--color-surface-2)" }}>
              <div>
                Cash expected in the drawer: <b className="tabular-nums">{money(Number(status.expected_cash), currency)}</b>
              </div>
              <input
                className="field mt-2 h-10 text-sm"
                inputMode="decimal"
                placeholder="Cash counted (optional — shows any difference)"
                value={counted}
                onChange={(e) => setCounted(e.target.value)}
              />
            </div>
          )}
          <input className="field mt-2 h-10 text-sm" placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} />
          {confirm === "close" ? (
            <div className="mt-2 flex gap-2">
              <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirm(null)}>
                Not yet
              </button>
              <button className="btn btn-pay flex-1 text-sm" disabled={pending} onClick={() => run(() => closeDay(notes, counted.trim() === "" ? null : Number(counted)))}>
                {pending ? "Closing…" : `Close ${niceDate(d.business_date)}`}
              </button>
            </div>
          ) : (
            <button className="btn btn-primary mt-2 w-full text-sm" disabled={blocked || pending} onClick={() => setConfirm("close")}>
              Close the day…
            </button>
          )}
        </div>
      )}

      {lastClosed && (status.can_reopen || canAsk) && (
        <details className="mt-4 rounded-lg border p-3" style={{ borderColor: "var(--color-line)" }}>
          <summary className="cursor-pointer text-sm font-semibold">Reopen {niceDate(lastClosed.business_date)}</summary>
          <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Only the last closed day can be reopened, and only when nothing has been billed since (void any new bills first). All
            changes then go into that day. Close it again when you are done. This is recorded with your name and reason.
          </p>
          <input className="field mt-2 h-10 text-sm" placeholder="Reason (required)" value={reason} onChange={(e) => setReason(e.target.value)} />
          {confirm === "reopen" ? (
            <div className="mt-2 flex gap-2">
              <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setConfirm(null)}>
                Cancel
              </button>
              <button className="btn flex-1 text-sm text-white" style={{ background: "var(--color-bad)" }} disabled={pending} onClick={() => run(() => reopenDay(reason))}>
                {pending ? "Reopening…" : "Confirm reopen"}
              </button>
            </div>
          ) : (
            <button className="btn mt-2 w-full border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={reason.trim().length < 3} onClick={() => setConfirm("reopen")}>
              Reopen…
            </button>
          )}
        </details>
      )}

      {msg && (
        <p
          className="mt-3 rounded-lg px-3 py-2 text-sm"
          role={msg.ok ? "status" : "alert"}
          style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad)" }}
        >
          {msg.text}
        </p>
      )}

      {status.recent.length > 0 && (
        <div className="mt-5">
          <h3 className="mb-2 text-sm font-bold">End-of-day reports</h3>
          <ul className="divide-y text-sm" style={{ borderColor: "var(--color-line)" }}>
            {d && (
              <li className="flex items-center justify-between py-2">
                <span>{niceDate(d.business_date)} · open</span>
                <Link href={`/shift/day/${d.id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                  So far →
                </Link>
              </li>
            )}
            {status.recent.map((x) => (
              <li key={x.id} className="flex items-center justify-between py-2">
                <span>
                  {niceDate(x.business_date)} · {x.status === "parked" ? "waiting (a day was reopened)" : "closed"}
                  {x.total != null && <span style={{ color: "var(--color-ink-3)" }}> · {money(Number(x.total), currency)}</span>}
                </span>
                <Link href={`/shift/day/${x.id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                  Report →
                </Link>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
