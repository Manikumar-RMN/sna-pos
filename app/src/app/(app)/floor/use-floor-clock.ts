"use client";

import { useEffect, useRef, useState } from "react";

/**
 * How long ago (in ms) the floor rows were fetched on this device, updated every `tickMs`.
 * Pass it to classifyTable(row, elapsedMs): the database clock + this = now, so a wrong clock on the tablet cannot colour a table wrongly,
 * and a table turns "late" on screen even when the page is not refreshed for a while.
 * Resets whenever `rows` is a new array (a fresh answer from the server).
 */
export function useFloorClock(rows: unknown, tickMs = 30_000): number {
  const fetchedAt = useRef(Date.now());
  const last = useRef<unknown>(rows);
  if (last.current !== rows) {
    last.current = rows;
    fetchedAt.current = Date.now();
  }
  const [, setTick] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setTick((n) => n + 1), tickMs);
    return () => clearInterval(t);
  }, [tickMs]);
  return Math.max(0, Date.now() - fetchedAt.current);
}
