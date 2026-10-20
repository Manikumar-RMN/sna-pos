"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { playNewTicketSound, readSoundWanted, saveSoundWanted, soundReady, soundSupported, unlockSound, watchSound } from "../kitchen/sound";
import { ackReadyAlert, fetchReadyAlerts, type ReadyAlert } from "./actions";

/**
 * "Food ready" alert for the waiter. Every few seconds it asks for tickets the kitchen marked Ready on tables
 * this waiter opened; each one shows as a banner with a beep and a buzz until the waiter taps "Got it".
 */
export function ReadyAlerts() {
  const [alerts, setAlerts] = useState<ReadyAlert[]>([]);
  const known = useRef<Set<string> | null>(null);
  const [wanted, setWanted] = useState(false);
  const [live, setLive] = useState(false);
  const [missing, setMissing] = useState(false);
  const soundButton = useRef<HTMLButtonElement>(null);
  const wantedRef = useRef(false);
  wantedRef.current = wanted;

  const load = useCallback(async () => {
    const list = await fetchReadyAlerts();
    const before = known.current;
    known.current = new Set(list.map((a) => a.ticketId));
    setAlerts(list);
    // The first load only shows what is waiting; a beep is for food that became ready after that.
    if (before && list.some((a) => !before.has(a.ticketId))) {
      if (wantedRef.current && soundReady()) playNewTicketSound();
      try {
        navigator.vibrate?.([250, 120, 250]);
      } catch {
        /* not every phone can vibrate */
      }
    }
  }, []);

  useEffect(() => {
    load();
    const t = setInterval(load, 8000);
    const onVisible = () => document.visibilityState === "visible" && load();
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      clearInterval(t);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [load]);

  useEffect(() => {
    setWanted(readSoundWanted());
    setMissing(!soundSupported());
    setLive(soundReady());
    return watchSound(() => setLive(soundReady()));
  }, []);

  // The sound was chosen on this phone before, but the page was reloaded: the next tap switches it back on.
  useEffect(() => {
    if (!wanted || live) return;
    const unlock = (e: Event) => {
      if (e.target instanceof Node && soundButton.current?.contains(e.target)) return;
      unlockSound();
    };
    const events = ["click", "touchend", "keydown"] as const;
    events.forEach((e) => window.addEventListener(e, unlock));
    return () => events.forEach((e) => window.removeEventListener(e, unlock));
  }, [wanted, live]);

  const soundOn = wanted && live;
  function toggleSound() {
    if (soundOn) {
      saveSoundWanted(false);
      setWanted(false);
      return;
    }
    if (!unlockSound()) {
      setMissing(true);
      return;
    }
    saveSoundWanted(true);
    setWanted(true);
    playNewTicketSound();
  }

  async function gotIt(id: string) {
    setAlerts((a) => a.filter((x) => x.ticketId !== id));
    known.current?.delete(id);
    await ackReadyAlert(id);
  }

  return (
    <div className="mb-3 space-y-2">
      {alerts.map((a) => (
        <div key={a.ticketId} role="alert" className="flex items-start gap-3 rounded-xl border-2 px-3 py-2.5" style={{ borderColor: "var(--color-ok)", background: "var(--color-ok-soft)" }}>
          <div className="min-w-0 flex-1">
            <div className="text-sm font-extrabold" style={{ color: "var(--color-ok)" }}>
              Food ready · {a.table ? `Table ${a.table}` : `Bill ${a.bill}`}
            </div>
            <div className="text-xs" style={{ color: "var(--color-ink-2)" }}>
              {a.items.map((i) => `${i.qty}× ${i.name}`).join(", ") || a.ticket}
              {a.station && a.station !== "Kitchen" ? ` · ${a.station}` : ""}
            </div>
          </div>
          <button className="btn btn-primary shrink-0 text-sm" style={{ minHeight: 40 }} onClick={() => gotIt(a.ticketId)}>
            Got it
          </button>
        </div>
      ))}
      {!missing && (
        <div className="flex justify-end">
          <button
            ref={soundButton}
            type="button"
            onClick={toggleSound}
            aria-pressed={soundOn}
            className="rounded-full border px-3 py-1 text-[11px] font-bold"
            style={
              soundOn
                ? { borderColor: "var(--color-ok)", background: "var(--color-ok-soft)", color: "var(--color-ok)" }
                : { borderColor: "var(--color-warn)", background: "var(--color-warn-soft)", color: "var(--color-warn)" }
            }
          >
            {soundOn ? "Food-ready beep on" : "Beep is off — tap to turn on"}
          </button>
        </div>
      )}
    </div>
  );
}
