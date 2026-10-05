"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState, useTransition } from "react";
import type { Fail } from "./helpers";

/** Small pieces shared by the Purchases tabs. */

export type Note = { ok: boolean; text: string } | null;

/** Row buttons: at least 40px tall so they are easy to hit on a tablet. */
export const rowBtn = "inline-flex min-h-10 items-center justify-center whitespace-nowrap rounded-xl border px-3 text-sm font-semibold";
export const lineStyle: React.CSSProperties = { borderColor: "var(--color-line)" };

export function Msg({ msg }: { msg: Note }) {
  if (!msg) return null;
  return (
    <p
      className="rounded-lg px-3 py-2 text-sm"
      role={msg.ok ? "status" : "alert"}
      style={msg.ok ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-bad-soft)", color: "var(--color-bad)" }}
    >
      {msg.text}
    </p>
  );
}

export function Badge({ label, bg, fg }: { label: string; bg: string; fg: string }) {
  return (
    <span className="inline-block whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-bold" style={{ background: bg, color: fg }}>
      {label}
    </span>
  );
}

/** Shown on the other tabs until there is a supplier to buy from. */
export function AddSupplierFirst() {
  return (
    <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
      <div className="font-display text-base font-bold" style={{ color: "var(--color-ink)" }}>
        Add a supplier first
      </div>
      <p className="mt-1">You need at least one active supplier before you can order or receive goods.</p>
      <Link href="/purchases?tab=suppliers" className="btn btn-primary mt-4 px-5 text-sm">
        Add a supplier
      </Link>
    </div>
  );
}

type Ok = { ok: true; message?: string };

/**
 * Runs a server action once at a time. A second tap while the first is still
 * on its way does nothing, and a dropped connection shows a message instead of
 * an error screen.
 */
export function useRun() {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<Note>(null);
  const busy = useRef(false);

  function run<R extends Ok>(
    fn: () => Promise<R | Fail>,
    /** Called after a success. Return the words to show (or a whole note), or nothing to use the action's own message. */
    onOk?: (r: R) => string | Note | void,
    offline = "Could not reach the server. Check the connection and try again.",
  ) {
    if (busy.current) return;
    busy.current = true;
    setMsg(null);
    start(async () => {
      try {
        const r = await fn();
        if (r.ok) {
          const out = onOk?.(r);
          setMsg(out && typeof out === "object" ? out : { ok: true, text: out || r.message || "Saved." });
        } else {
          setMsg({ ok: false, text: r.error });
        }
      } catch {
        setMsg({ ok: false, text: offline });
      } finally {
        busy.current = false;
        // Also after a failure: the screen may be out of date, which is often why it failed.
        router.refresh();
      }
    });
  }

  return { pending, msg, setMsg, run };
}

/**
 * A button that asks before it acts. The first tap turns it into the question
 * with "yes" and "no" beside it; nothing happens until "yes" is tapped. No
 * browser dialog, so it also works on kiosk tablets.
 */
export function Confirm({
  children,
  question,
  yes,
  no = "Keep",
  onYes,
  disabled,
  danger = true,
}: {
  children: React.ReactNode;
  question: string;
  yes: string;
  no?: string;
  onYes: () => void;
  disabled?: boolean;
  danger?: boolean;
}) {
  const [asking, setAsking] = useState(false);
  if (!asking) {
    return (
      <button type="button" className={rowBtn} style={{ ...lineStyle, color: danger ? "var(--color-bad)" : undefined }} disabled={disabled} onClick={() => setAsking(true)}>
        {children}
      </button>
    );
  }
  return (
    <span role="group" aria-label={question} className="inline-flex flex-wrap items-center gap-1.5">
      <span className="text-sm font-semibold">{question}</span>
      <button
        type="button"
        className={rowBtn}
        style={danger ? { borderColor: "var(--color-bad)", background: "var(--color-bad)", color: "#fff" } : { borderColor: "var(--color-brand)", background: "var(--color-brand)", color: "#fff" }}
        disabled={disabled}
        onClick={() => {
          setAsking(false);
          onYes();
        }}
      >
        {yes}
      </button>
      <button type="button" autoFocus className={rowBtn} style={{ ...lineStyle, background: "var(--color-surface)", color: "var(--color-ink-2)" }} onClick={() => setAsking(false)}>
        {no}
      </button>
    </span>
  );
}

/** A labelled field: the label is always visible, so nothing needs explaining. */
export function Field({ label, hint, children, className }: { label: string; hint?: string; children: React.ReactNode; className?: string }) {
  return (
    <label className={`block ${className ?? ""}`}>
      <span className="mb-1 block text-xs font-semibold" style={{ color: "var(--color-ink-2)" }}>
        {label}
        {hint && (
          <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>
            {" "}
            {hint}
          </span>
        )}
      </span>
      {children}
    </label>
  );
}
