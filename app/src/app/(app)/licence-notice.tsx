"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useRef, useState } from "react";

type Props = {
  state: "ok" | "warn" | "locked";
  reason: string | null;
  /** End date already written out, e.g. "20 Oct 2026". */
  endsText: string;
  daysLeft: number | null;
  remind: boolean;
  restaurantId: string;
};

/** Screens that only change things. They are closed while the restaurant is read-only. */
const CLOSED_WHEN_LOCKED = ["/pos", "/settings", "/stock", "/purchases", "/welcome", "/table-orders", "/reservations", "/loyalty", "/timesheets"];

const lockedTitle = (reason: string | null) =>
  reason === "suspended" || reason === "cancelled" ? "This SNA POS account is on hold" : "Your SNA POS licence has ended";

function lockedLine(reason: string | null, endsText: string) {
  if (reason === "suspended" || reason === "cancelled") return "SNA has put this account on hold, so it is read-only.";
  return endsText ? `The licence ended on ${endsText}, so SNA POS is read-only.` : "The licence has ended, so SNA POS is read-only.";
}

/** Morning and afternoon each get their own reminder: twice a day on every device. */
function slotNow(): string {
  const d = new Date();
  const day = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  return `${day}#${d.getHours() < 14 ? "am" : "pm"}`;
}

/**
 * The licence reminder (a pop-up, twice a day, from 15 days before the end date)
 * and the strip that says the restaurant is read-only.
 */
export function LicenceNotice({ state, reason, endsText, daysLeft, remind, restaurantId }: Props) {
  const [open, setOpen] = useState(false);
  const okRef = useRef<HTMLButtonElement>(null);
  const key = `sna.licence.reminded.${restaurantId}`;

  useEffect(() => {
    if (state !== "warn" || !remind) return;
    const check = () => {
      let seen: string | null = null;
      try {
        seen = window.localStorage.getItem(key);
      } catch {
        // No storage on this device: the reminder shows once each time the app is opened.
      }
      if (seen !== slotNow()) setOpen(true);
    };
    check();
    // A tablet left on the billing screen all day still gets the afternoon reminder.
    const t = window.setInterval(check, 10 * 60 * 1000);
    return () => window.clearInterval(t);
  }, [state, remind, key]);

  useEffect(() => {
    if (open) okRef.current?.focus();
  }, [open]);

  function close() {
    try {
      window.localStorage.setItem(key, slotNow());
    } catch {
      // Nothing to remember it in; it will show again next time the app is opened.
    }
    setOpen(false);
  }

  if (state === "locked") {
    return (
      <div role="alert" className="mb-3 rounded-2xl px-4 py-3 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
        <b>{lockedTitle(reason)}.</b> {lockedLine(reason, endsText)} You can still see and print bills and reports, take payment for bills that are already open,
        and close the day. New bills cannot be made. Please contact SNA to renew.
      </div>
    );
  }

  if (state !== "warn" || !remind || !open) return null;
  const when = daysLeft === 0 ? "today" : daysLeft === 1 ? "tomorrow" : `in ${daysLeft} days`;
  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      style={{ background: "rgba(34,26,18,0.55)" }}
      role="dialog"
      aria-modal="true"
      aria-labelledby="licence-title"
      onKeyDown={(e) => {
        if (e.key === "Escape") close();
      }}
    >
      <div className="card w-full max-w-md p-6">
        <h2 id="licence-title" className="font-display text-xl font-bold">
          Your SNA POS licence ends {when}
        </h2>
        <p className="mt-2 text-sm" style={{ color: "var(--color-ink-2)" }}>
          {endsText ? (
            <>
              The licence for this restaurant ends on <b>{endsText}</b>.
            </>
          ) : (
            "The licence for this restaurant is about to end."
          )}{" "}
          After that day SNA POS becomes read-only: you can see bills and reports, but you cannot make new bills.
        </p>
        <p className="mt-2 text-sm" style={{ color: "var(--color-ink-2)" }}>
          Please contact SNA to renew. If you have already paid, tell the owner: SNA will switch this reminder off.
        </p>
        <button ref={okRef} type="button" className="btn btn-primary mt-5 w-full" onClick={close}>
          OK
        </button>
        <p className="mt-2 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>
          This reminder shows twice a day until the licence is renewed.
        </p>
      </div>
    </div>
  );
}

/** While the restaurant is read-only, the screens that only change things show this instead. */
export function LicenceGate({ locked, reason, endsText, children }: { locked: boolean; reason: string | null; endsText: string; children: React.ReactNode }) {
  const path = usePathname() ?? "";
  if (!locked || !CLOSED_WHEN_LOCKED.some((p) => path === p || path.startsWith(`${p}/`))) return <>{children}</>;
  return (
    <div className="mx-auto max-w-lg">
      <div className="card p-6">
        <h1 className="font-display text-xl font-bold">This screen is closed</h1>
        <p className="mt-2 text-sm" style={{ color: "var(--color-ink-2)" }}>
          {lockedLine(reason, endsText)} Billing, settings, menu, stock and purchases are closed until the licence is renewed. Please contact SNA.
        </p>
        <p className="mt-3 text-sm font-semibold">You can still use:</p>
        <div className="mt-2 flex flex-wrap gap-2">
          {[
            { href: "/bills", label: "Bills (pay open bills, print)" },
            { href: "/shift", label: "Day close" },
            { href: "/reports", label: "Reports" },
            { href: "/dashboard", label: "Home" },
          ].map((l) => (
            <Link key={l.href} href={l.href} className="btn" style={{ border: "1px solid var(--color-line)", color: "var(--color-ink-2)" }}>
              {l.label}
            </Link>
          ))}
        </div>
      </div>
    </div>
  );
}
