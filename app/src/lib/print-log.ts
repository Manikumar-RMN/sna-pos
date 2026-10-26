/**
 * Print log helpers (reprint audit, F11 follow-up).
 *
 * Two jobs:
 *  1. Browser print (Ctrl+P / the browser menu). The app cannot stop that print, so a screen listens to the window's
 *     "beforeprint" event and records it. A print that the app started itself (the Print button) already logged first, so it
 *     marks itself with markAppPrint() and the listener skips it: one print action = one log row.
 *  2. Prints made while offline (a receipt shown from this device's own copy) and prints whose log call failed: they wait in a
 *     small queue in this browser (localStorage, like lib/offline.ts) and are sent through the logPrint server action when the
 *     internet is back, each once (a client ref per print), in order per bill, and an offline bill's print only after the bill
 *     itself is on the server.
 *
 * Everything that decides something is a pure function so it can be tested without a browser.
 */
import { useEffect, useRef } from "react";

export type PrintKind = "bill" | "kot";

/** One print waiting to be recorded. Identify the bill by `orderId` (online bill) or `billClientRef` (offline bill: its client_id). */
export type PrintEvent = {
  /** Client ref of this print action; a print is never sent twice with the same ref. */
  ref: string;
  kind: PrintKind;
  /** When the print happened (ISO). */
  at: string;
  orderId?: string;
  billClientRef?: string;
  ticketIds?: string[];
  /** The screen already knew this was a later copy (sent as isReprint: true). */
  isReprint: boolean;
  /** Made from the browser menu / Ctrl+P, which the app could not hold back for a check. */
  declared: boolean;
  tries?: number;
  /** The database wants the reprint right or a manager PIN; waits for a person (never retried by itself). */
  needs_approval?: boolean;
  /** Too many failed tries; kept on the device, no longer retried. */
  gave_up?: boolean;
  error?: string;
};

export type SendResult = { ok: true } | { ok: false; error: string; notSynced?: boolean; needsApproval?: boolean };

/** After this many failed tries a print stays in the queue but is no longer retried. */
export const MAX_PRINT_TRIES = 5;
/** The queue never grows beyond this many prints (oldest dropped first). */
export const MAX_QUEUE = 200;

// ---------------------------------------------------------------- browser print gate

/** A print the app started is ignored for this long if "afterprint" never arrives. */
export const APP_PRINT_TTL_MS = 30_000;
/** Two "beforeprint" events this close together are one print action. */
export const DUPLICATE_MS = 1500;

let appPrintAt: number | null = null;

/**
 * Call just before the app itself calls window.print() for a bill or ticket that it has already logged (or does not log).
 * The mark is cleared by the browser's "afterprint" (or after APP_PRINT_TTL_MS).
 */
export function markAppPrint(now: number = Date.now()): void {
  appPrintAt = now;
  if (typeof window !== "undefined") window.addEventListener("afterprint", clearAppPrint, { once: true });
}
export function clearAppPrint(): void {
  appPrintAt = null;
}
export function isAppPrint(now: number = Date.now()): boolean {
  return appPrintAt !== null && now - appPrintAt >= 0 && now - appPrintAt < APP_PRINT_TTL_MS;
}

/**
 * Decides, for each "beforeprint", whether this screen records a declared print. One gate per screen/kind.
 * "app" = the app's own print (already logged), "duplicate" = same print action seen twice, "log" = record it.
 */
export function createBrowserPrintGate(now: () => number = Date.now) {
  let last = -Infinity;
  return {
    check(): "app" | "duplicate" | "log" {
      const t = now();
      if (isAppPrint(t)) return "app";
      if (t - last < DUPLICATE_MS) return "duplicate";
      last = t;
      return "log";
    },
  };
}

/**
 * Calls `onDeclared` once per print action that the app did not start itself (Ctrl+P, browser menu, a browser print button).
 * `enabled` false = nothing is listened to (a preview, or nothing printable on screen).
 */
export function useBrowserPrint(enabled: boolean, onDeclared: () => void): void {
  const cb = useRef(onDeclared);
  useEffect(() => {
    cb.current = onDeclared;
  });
  useEffect(() => {
    if (!enabled) return;
    const gate = createBrowserPrintGate();
    const before = () => {
      if (gate.check() === "log") cb.current();
    };
    window.addEventListener("beforeprint", before);
    return () => window.removeEventListener("beforeprint", before);
  }, [enabled]);
}

// ---------------------------------------------------------------- queue (pure)

export const newPrintRef = (): string =>
  typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`;

/** Adds a print to the queue unless one with the same ref is already there. */
export function addPrintEvent(queue: PrintEvent[], ev: PrintEvent): PrintEvent[] {
  if (queue.some((e) => e.ref === ev.ref)) return queue;
  const next = [...queue, ev];
  return next.length > MAX_QUEUE ? next.slice(next.length - MAX_QUEUE) : next;
}

/** Which bill a print belongs to (prints of one bill are sent in order, and wait together). */
export const billKey = (ev: PrintEvent): string => ev.orderId ?? ev.billClientRef ?? ev.ref;

/** Queue after the server's answer for `ev`. */
export function applyPrintOutcome(queue: PrintEvent[], ev: PrintEvent, res: SendResult): PrintEvent[] {
  if (res.ok) return queue.filter((e) => e.ref !== ev.ref);
  // The offline bill is not on the server yet: nothing is wrong, just wait (the try is not counted).
  if (res.notSynced) return queue;
  if (res.needsApproval) return queue.map((e) => (e.ref === ev.ref ? { ...e, needs_approval: true, error: res.error } : e));
  const tries = (ev.tries ?? 0) + 1;
  return queue.map((e) => (e.ref === ev.ref ? { ...e, tries, error: res.error, gave_up: tries >= MAX_PRINT_TRIES } : e));
}

/** Maps what the logPrint action answered to a SendResult. */
export function toSendResult(res: { ok: true } | { ok: false; error: string; notSynced?: boolean }): SendResult {
  if (res.ok) return { ok: true };
  if (res.notSynced) return { ok: false, error: res.error, notSynced: true };
  return { ok: false, error: res.error, needsApproval: /\(order\.reprint\)/.test(res.error) };
}

export type FlushSummary = {
  sent: number;
  /** Prints of offline bills still waiting for the bill to reach the server. */
  waiting: number;
  needsApproval: number;
  gaveUp: number;
  /** The server could not be reached; the rest stays queued. */
  offline: boolean;
};

export type QueueStore = { read: () => PrintEvent[]; write: (q: PrintEvent[]) => void };

/** Counts for the banner. */
export function summarize(queue: PrintEvent[]): Pick<FlushSummary, "needsApproval" | "gaveUp"> & { total: number } {
  return { total: queue.length, needsApproval: queue.filter((e) => e.needs_approval && !e.gave_up).length, gaveUp: queue.filter((e) => e.gave_up).length };
}

/**
 * Sends the queued prints in order. A bill whose print is waiting (not synced yet, needs approval, gave up) holds back its later
 * prints too, so the log never sees copy 2 before copy 1. `send` throwing means no connection: stop, keep everything.
 * The queue is read again before every write, so a print added meanwhile is not lost.
 */
export async function flushPrintQueue(send: (ev: PrintEvent) => Promise<SendResult>, store: QueueStore = browserStore): Promise<FlushSummary> {
  const out: FlushSummary = { sent: 0, waiting: 0, needsApproval: 0, gaveUp: 0, offline: false };
  const blocked = new Set<string>();
  for (const ev of store.read()) {
    const key = billKey(ev);
    if (ev.gave_up || ev.needs_approval) {
      blocked.add(key);
      continue;
    }
    if (blocked.has(key)) continue;
    let res: SendResult;
    try {
      res = await send(ev);
    } catch {
      out.offline = true;
      break;
    }
    if (res.ok) out.sent += 1;
    else blocked.add(key);
    store.write(applyPrintOutcome(store.read(), ev, res));
  }
  const left = store.read();
  out.needsApproval = left.filter((e) => e.needs_approval && !e.gave_up).length;
  out.gaveUp = left.filter((e) => e.gave_up).length;
  out.waiting = left.filter((e) => !e.needs_approval && !e.gave_up).length;
  return out;
}

/** Tries one print that was waiting for approval, once (the person has just entered a manager PIN). */
export async function retryApproved(ref: string, send: (ev: PrintEvent) => Promise<SendResult>, store: QueueStore = browserStore): Promise<boolean> {
  const ev = store.read().find((e) => e.ref === ref);
  if (!ev) return true;
  const again: PrintEvent = { ...ev, needs_approval: false };
  const res = await send(again);
  store.write(applyPrintOutcome(store.read(), again, res));
  return res.ok;
}

// ---------------------------------------------------------------- recording a declared print

export type DeclaredOutcome =
  | { status: "recorded"; reprint: boolean; printNo?: number }
  /** No connection: saved in the device queue, sent later. */
  | { status: "offline"; ref: string }
  /** The database wants the reprint right or a manager PIN: saved in the device queue as waiting for approval. */
  | { status: "needs_approval"; ref: string; error: string }
  /** Any other refusal: saved in the device queue, retried a few times. */
  | { status: "failed"; ref: string; error: string };

export type LogAnswer = { ok: true; reprint: boolean; printNo?: number } | { ok: false; error: string; notSynced?: boolean };

/**
 * Records one print that the app could not hold back (Ctrl+P). Whatever happens it ends with the print either in the log or in the
 * device queue, so it is not lost. `send` is the logPrint server action (injected so this stays testable).
 */
export async function recordDeclaredPrint(
  base: { kind: PrintKind; orderId?: string; billClientRef?: string; ticketIds?: string[]; isReprint: boolean },
  send: (ev: PrintEvent) => Promise<LogAnswer>,
  store: QueueStore = browserStore,
  ref: string = newPrintRef(),
  now: () => Date = () => new Date(),
): Promise<DeclaredOutcome> {
  const ev: PrintEvent = { ...base, ref, at: now().toISOString(), declared: true };
  const keep = (extra: Partial<PrintEvent>) => store.write(addPrintEvent(store.read(), { ...ev, ...extra }));
  let res: LogAnswer;
  try {
    res = await send(ev);
  } catch {
    keep({});
    return { status: "offline", ref };
  }
  if (res.ok) return { status: "recorded", reprint: res.reprint, printNo: res.printNo };
  const r = toSendResult(res);
  if (!r.ok && r.needsApproval) {
    keep({ needs_approval: true, error: r.error });
    return { status: "needs_approval", ref, error: r.error };
  }
  keep({ error: res.error });
  return { status: "failed", ref, error: res.error };
}

// ---------------------------------------------------------------- browser storage

const K_PRINTS = "sna.print-log.queue.v1";
const CHANGED = "sna-print-queue";

export function readPrintQueue(): PrintEvent[] {
  try {
    const v = localStorage.getItem(K_PRINTS);
    const parsed: unknown = v ? JSON.parse(v) : [];
    return Array.isArray(parsed) ? (parsed as PrintEvent[]).filter((e) => e && typeof e.ref === "string") : [];
  } catch {
    return [];
  }
}

export function writePrintQueue(q: PrintEvent[]): boolean {
  try {
    localStorage.setItem(K_PRINTS, JSON.stringify(q));
    if (typeof window !== "undefined") window.dispatchEvent(new Event(CHANGED));
    return true;
  } catch {
    return false;
  }
}

const browserStore: QueueStore = { read: readPrintQueue, write: (q) => void writePrintQueue(q) };

/** Puts a print in the queue (once per ref). Returns false when this device's storage is full or blocked. */
export function enqueuePrint(ev: PrintEvent): boolean {
  return writePrintQueue(addPrintEvent(readPrintQueue(), ev));
}

export function dropPrint(ref: string): void {
  writePrintQueue(readPrintQueue().filter((e) => e.ref !== ref));
}

export const PRINT_QUEUE_CHANGED = CHANGED;
