"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { readAccountDate, type AccountDateInfo } from "./account-date-action";

function label(ymd: string) {
  const d = new Date(`${ymd}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return ymd;
  return d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "UTC" });
}

/**
 * "Account date" at the top right: the business date the next bill goes on.
 * It changes at the day cutoff, not at midnight, and stays on an earlier day while that
 * day is still open (unpaid bills or an open shift keep it open). Read again every few
 * minutes and when the screen comes back into view, so a tablet left open overnight is right.
 */
export function AccountDate({ initial, onGreen }: { initial: AccountDateInfo; onGreen: boolean }) {
  const [info, setInfo] = useState(initial);
  useEffect(() => {
    let alive = true;
    const refresh = () => {
      readAccountDate()
        .then((v) => {
          if (alive && v) setInfo(v);
        })
        .catch(() => {});
    };
    const timer = window.setInterval(refresh, 5 * 60 * 1000);
    const onShow = () => {
      if (document.visibilityState === "visible") refresh();
    };
    document.addEventListener("visibilitychange", onShow);
    return () => {
      alive = false;
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", onShow);
    };
  }, []);

  if (!info) return null;
  const text = label(info.date);
  const style = info.oldDay
    ? { background: "var(--color-warn-soft)", color: "var(--color-warn)" }
    : onGreen
      ? { color: "#fff" }
      : { color: "var(--color-ink)" };
  const body = (
    <span className="block text-right leading-tight">
      <span className="block text-[10px] font-semibold uppercase tracking-wide" style={{ opacity: 0.75 }}>
        Account date
      </span>
      <span className="block whitespace-nowrap text-sm font-bold tabular-nums">{text}</span>
      {info.oldDay && <span className="block text-[10px] font-bold uppercase tracking-wide">Day not closed - tap to close</span>}
    </span>
  );
  return info.oldDay ? (
    <Link
      href="/shift"
      className="rounded-lg px-2 py-1"
      style={style}
      title="The previous day is still open (unpaid bills or an open shift). New bills go on this date until it is closed. Open Day close."
    >
      {body}
    </Link>
  ) : (
    <span className="px-1" style={style} title="The business date new bills go on. It moves to the next day at your day cutoff time.">
      {body}
    </span>
  );
}
