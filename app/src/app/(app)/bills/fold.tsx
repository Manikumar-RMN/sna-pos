"use client";

import { useState, type ReactNode } from "react";

/** A section folded away behind one button until it is needed. Its content stays mounted, so typed values are kept. */
export function Fold({ label, children, defaultOpen = false }: { label: string; children: ReactNode; defaultOpen?: boolean }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="no-print">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="btn w-full border text-sm"
        style={{ borderColor: open ? "var(--color-brand)" : "var(--color-line)", color: open ? "var(--color-brand-strong)" : "var(--color-ink-2)" }}
      >
        {label} {open ? "▴" : "▾"}
      </button>
      <div className={open ? "mt-2" : "hidden"}>{children}</div>
    </div>
  );
}
