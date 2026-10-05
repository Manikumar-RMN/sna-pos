"use client";

import { useEffect, useRef } from "react";
import { usePathname, useRouter } from "next/navigation";
import { keepCounterAlive, lockCounter } from "@/app/counter/actions";

/** Kitchen screen only: when it was opened or last touched, and whether it was ever left alone past the limit. */
type KitchenWatch = { last: number; unattended: boolean };
const KITCHEN_KEY = "sna.kitchen.watch.v1";

/** What was saved before a reload of the kitchen screen, if anything usable. */
function savedWatch(): KitchenWatch | null {
  try {
    const v: unknown = JSON.parse(window.sessionStorage.getItem(KITCHEN_KEY) ?? "null");
    if (v && typeof v === "object") {
      const { last, unattended } = v as { last?: unknown; unattended?: unknown };
      if (typeof last === "number" && Number.isFinite(last) && last <= Date.now() && typeof unattended === "boolean") {
        return { last, unattended };
      }
    }
  } catch {
    /* nothing saved, or storage is switched off */
  }
  return null;
}

function saveWatch(k: KitchenWatch | null) {
  try {
    if (k) window.sessionStorage.setItem(KITCHEN_KEY, JSON.stringify(k));
    else window.sessionStorage.removeItem(KITCHEN_KEY);
  } catch {
    /* storage is switched off: the watch still works until the page is reloaded */
  }
}

/**
 * On a shared counter tablet: tells the server the tablet is in use (at most
 * once a minute), and locks the screen after a few minutes without a touch.
 * The server enforces the same limit, so a sleeping tablet that wakes up is
 * already locked — on wake we simply refresh to show the PIN screen.
 *
 * The kitchen screen is the exception: cooks watch it without touching it, so
 * while it is open the idle timer is not running and waking up never locks.
 * That screen refreshes itself every 10 seconds, and every refresh tells the
 * server the tablet is in use, so the PIN session stays alive for as long as
 * the screen is really showing. If the tablet sleeps there for long enough the
 * server ends the session by itself; on wake we refresh, and the server shows
 * the PIN screen.
 *
 * Leaving the kitchen screen is where care is needed. If the tablet sat on it
 * untouched for longer than the limit at any point, nobody can say who is
 * tapping now, so going to any other screen asks for the PIN first. Touching
 * the kitchen board after that (marking a dish ready) does not change this,
 * and neither does reloading the page. Someone who only glanced at the kitchen
 * screen and went back carries on as normal, with the usual timer.
 */
export function IdleLock({ minutes }: { minutes: number }) {
  const router = useRouter();
  const pathname = usePathname();
  const onKitchen = pathname === "/kitchen" || pathname.startsWith("/kitchen/");
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastPing = useRef(Date.now());
  const lastActivity = useRef(Date.now());
  const kitchen = useRef<KitchenWatch | null>(null);
  /** False until the first screen has been seen: only a page that loads straight onto the kitchen screen picks up a saved watch. */
  const started = useRef(false);

  useEffect(() => {
    const limit = minutes * 60 * 1000;
    const lock = () => {
      lockCounter().catch(() => window.location.assign("/counter"));
    };
    const arm = () => {
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(lock, limit);
    };
    const activity = () => {
      const now = Date.now();
      lastActivity.current = now;
      const k = kitchen.current;
      if (onKitchen && k) {
        // One tap arrives as two events (touch and pointer); the second sees a gap of a few milliseconds and changes nothing.
        if (now - k.last > limit) k.unattended = true;
        k.last = now;
        saveWatch(k);
      } else if (!onKitchen) arm();
      if (now - lastPing.current > 60_000) {
        lastPing.current = now;
        keepCounterAlive()
          .then((alive) => {
            if (!alive) window.location.assign("/counter");
          })
          .catch(() => {});
      }
    };
    const wake = () => {
      if (document.visibilityState !== "visible") return;
      if (!onKitchen && Date.now() - lastActivity.current > limit) lock();
      else router.refresh();
    };
    const events = ["pointerdown", "keydown", "touchstart"] as const;
    events.forEach((e) => window.addEventListener(e, activity, { passive: true }));
    document.addEventListener("visibilitychange", wake);
    window.addEventListener("focus", wake);

    if (onKitchen) {
      // Opening the kitchen screen starts its own count. A re-run of this effect while it stays open does not,
      // and a reload of the page carries on with the count it had.
      if (!kitchen.current) {
        kitchen.current = (!started.current && savedWatch()) || { last: Date.now(), unattended: false };
        saveWatch(kitchen.current);
      }
    } else {
      const k = kitchen.current;
      kitchen.current = null;
      saveWatch(null);
      // Just left the kitchen screen. The tap that did it has already been counted in activity() above.
      if (k && (k.unattended || Date.now() - k.last > limit)) lock();
      else arm();
    }
    started.current = true;

    return () => {
      if (timer.current) clearTimeout(timer.current);
      timer.current = null;
      events.forEach((e) => window.removeEventListener(e, activity));
      document.removeEventListener("visibilitychange", wake);
      window.removeEventListener("focus", wake);
    };
  }, [minutes, router, onKitchen]);

  return null;
}
