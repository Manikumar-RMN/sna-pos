"use client";

import { useRef, useState } from "react";

/**
 * A remove button that asks first. The first tap turns it into
 * "Remove …?  Yes, remove / Keep" on the same line; nothing is removed until
 * "Yes, remove" is tapped. No browser dialog, so it also works on kiosk tablets.
 */
export function ConfirmButton({
  children,
  question,
  onConfirm,
  disabled,
  className = "rounded-lg px-2 py-1.5 text-xs font-semibold",
  style = { color: "var(--color-bad)" },
  ariaLabel,
  yesLabel = "Yes, remove",
  noLabel = "Keep",
  tone = "danger",
}: {
  /** What the button says before it is tapped. */
  children: React.ReactNode;
  /** The question shown after the first tap, e.g. "Remove table 4?". */
  question: string;
  onConfirm: () => void;
  disabled?: boolean;
  className?: string;
  style?: React.CSSProperties;
  ariaLabel?: string;
  yesLabel?: string;
  noLabel?: string;
  /** "danger" (red) for removing something; "plain" for an action that only needs a second look. */
  tone?: "danger" | "plain";
}) {
  const [asking, setAsking] = useState(false);
  // When the question appeared, so a hurried double tap cannot land on "Yes, remove".
  const askedAt = useRef(0);
  // After "Keep", the keyboard focus goes back to the remove button.
  const refocus = useRef(false);

  function keep() {
    refocus.current = true;
    setAsking(false);
  }

  if (!asking) {
    return (
      <button
        type="button"
        ref={(el) => {
          if (el && refocus.current) {
            refocus.current = false;
            el.focus();
          }
        }}
        className={className}
        style={style}
        disabled={disabled}
        aria-label={ariaLabel}
        onClick={() => {
          askedAt.current = Date.now();
          setAsking(true);
        }}
      >
        {children}
      </button>
    );
  }

  return (
    <span
      role="group"
      aria-label={question}
      className="inline-flex flex-wrap items-center justify-end gap-1.5 text-left"
      onKeyDown={(e) => {
        if (e.key === "Escape") {
          e.stopPropagation();
          keep();
        }
      }}
    >
      <span className="text-xs font-semibold" style={{ color: "var(--color-ink)" }}>
        {question}
      </span>
      <button
        type="button"
        className="min-h-9 whitespace-nowrap rounded-lg px-3 text-xs font-bold"
        style={{ background: tone === "plain" ? "var(--color-brand)" : "var(--color-bad)", color: "#fff" }}
        disabled={disabled}
        onClick={() => {
          if (Date.now() - askedAt.current < 400) return;
          setAsking(false);
          onConfirm();
        }}
      >
        {yesLabel}
      </button>
      <button
        type="button"
        autoFocus
        className="min-h-9 whitespace-nowrap rounded-lg border px-3 text-xs font-bold"
        style={{ borderColor: "var(--color-line)", background: "var(--color-surface)", color: "var(--color-ink-2)" }}
        onClick={keep}
      >
        {noLabel}
      </button>
    </span>
  );
}
