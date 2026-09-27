"use client";

import { useEffect, useRef } from "react";
import { useRouter } from "next/navigation";
import { keepCounterAlive, lockCounter } from "@/app/counter/actions";

/**
 * On a shared counter tablet: tells the server the tablet is in use (at most
 * once a minute), and locks the screen after a few minutes without a touch.
 * The server enforces the same limit, so a sleeping tablet that wakes up is
 * already locked — on wake we simply refresh to show the PIN screen.
 */
export function IdleLock({ minutes }: { minutes: number }) {
  const router = useRouter();
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastPing = useRef(Date.now());
  const lastActivity = useRef(Date.now());

  useEffect(() => {
    const lock = () => {
      lockCounter().catch(() => window.location.assign("/counter"));
    };
    const arm = () => {
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(lock, minutes * 60 * 1000);
    };
    const activity = () => {
      lastActivity.current = Date.now();
      arm();
      if (Date.now() - lastPing.current > 60_000) {
        lastPing.current = Date.now();
        keepCounterAlive()
          .then((alive) => {
            if (!alive) window.location.assign("/counter");
          })
          .catch(() => {});
      }
    };
    const wake = () => {
      if (document.visibilityState !== "visible") return;
      if (Date.now() - lastActivity.current > minutes * 60 * 1000) lock();
      else router.refresh();
    };
    const events = ["pointerdown", "keydown", "touchstart"] as const;
    events.forEach((e) => window.addEventListener(e, activity, { passive: true }));
    document.addEventListener("visibilitychange", wake);
    window.addEventListener("focus", wake);
    arm();
    return () => {
      if (timer.current) clearTimeout(timer.current);
      events.forEach((e) => window.removeEventListener(e, activity));
      document.removeEventListener("visibilitychange", wake);
      window.removeEventListener("focus", wake);
    };
  }, [minutes, router]);

  return null;
}
