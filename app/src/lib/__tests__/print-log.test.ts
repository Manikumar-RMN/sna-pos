import { afterEach, describe, expect, it } from "vitest";
import {
  APP_PRINT_TTL_MS,
  DUPLICATE_MS,
  MAX_PRINT_TRIES,
  addPrintEvent,
  applyPrintOutcome,
  clearAppPrint,
  createBrowserPrintGate,
  flushPrintQueue,
  markAppPrint,
  recordDeclaredPrint,
  retryApproved,
  toSendResult,
  type PrintEvent,
  type QueueStore,
  type SendResult,
} from "../print-log";

const ev = (ref: string, extra: Partial<PrintEvent> = {}): PrintEvent => ({ ref, kind: "bill", at: "2026-10-26T10:00:00Z", isReprint: false, declared: false, ...extra });
const memory = (start: PrintEvent[] = []): QueueStore & { q: PrintEvent[] } => {
  const m = { q: start, read: () => m.q, write: (q: PrintEvent[]) => void (m.q = q) };
  return m;
};

afterEach(() => clearAppPrint());

describe("browser print gate: one print action, one log row", () => {
  it("skips a print the app started itself (the Print button already logged it)", () => {
    let t = 1000;
    const gate = createBrowserPrintGate(() => t);
    markAppPrint(t);
    expect(gate.check()).toBe("app");
    clearAppPrint(); // afterprint
    t += 5000;
    expect(gate.check()).toBe("log");
  });

  it("logs a Ctrl+P once, even if the browser fires beforeprint twice", () => {
    let t = 1000;
    const gate = createBrowserPrintGate(() => t);
    expect(gate.check()).toBe("log");
    t += DUPLICATE_MS - 1;
    expect(gate.check()).toBe("duplicate");
    t += DUPLICATE_MS;
    expect(gate.check()).toBe("log");
  });

  it("a mark left behind (no afterprint) expires, so a later Ctrl+P is still logged", () => {
    let t = 1000;
    const gate = createBrowserPrintGate(() => t);
    markAppPrint(t);
    t += APP_PRINT_TTL_MS + 1;
    expect(gate.check()).toBe("log");
  });

  it("two screens listening each log their own kind once", () => {
    const t = 1000;
    const a = createBrowserPrintGate(() => t);
    const b = createBrowserPrintGate(() => t);
    expect([a.check(), b.check()]).toEqual(["log", "log"]);
  });
});

describe("print queue", () => {
  it("never adds the same client ref twice", () => {
    const q = addPrintEvent(addPrintEvent([], ev("a")), ev("a"));
    expect(q).toHaveLength(1);
  });

  it("a recorded print leaves the queue", () => {
    expect(applyPrintOutcome([ev("a"), ev("b")], ev("a"), { ok: true }).map((e) => e.ref)).toEqual(["b"]);
  });

  it("an offline bill that is not on the server yet just waits, without counting a failure", () => {
    const q = applyPrintOutcome([ev("a", { billClientRef: "c1" })], ev("a"), { ok: false, error: "x", notSynced: true });
    expect(q[0].tries).toBeUndefined();
    expect(q[0].gave_up).toBeUndefined();
  });

  it("needing the reprint right parks the print for a person", () => {
    const q = applyPrintOutcome([ev("a")], ev("a"), { ok: false, error: "Not allowed (order.reprint)", needsApproval: true });
    expect(q[0].needs_approval).toBe(true);
  });

  it(`gives up after ${MAX_PRINT_TRIES} failed tries but keeps the print`, () => {
    let q = [ev("a")];
    for (let i = 0; i < MAX_PRINT_TRIES; i++) q = applyPrintOutcome(q, q[0], { ok: false, error: "boom" });
    expect(q).toHaveLength(1);
    expect(q[0].gave_up).toBe(true);
  });

  it("toSendResult recognises the PIN message and the not-synced answer", () => {
    expect(toSendResult({ ok: false, error: "You are not allowed (order.reprint)" })).toMatchObject({ needsApproval: true });
    expect(toSendResult({ ok: false, error: "wait", notSynced: true })).toMatchObject({ notSynced: true });
    expect(toSendResult({ ok: false, error: "Bill not found." })).toMatchObject({ needsApproval: false });
  });
});

describe("flushPrintQueue", () => {
  it("sends in order and empties the queue", async () => {
    const store = memory([ev("a", { orderId: "o1" }), ev("b", { orderId: "o1", isReprint: true })]);
    const seen: string[] = [];
    const out = await flushPrintQueue(async (e) => (seen.push(e.ref), { ok: true }), store);
    expect(seen).toEqual(["a", "b"]);
    expect(store.q).toEqual([]);
    expect(out.sent).toBe(2);
  });

  it("a reprint of a bill that has not synced yet waits for the bill, and holds back later prints of the same bill only", async () => {
    const store = memory([
      ev("first", { billClientRef: "c1" }),
      ev("second", { billClientRef: "c1", isReprint: true }),
      ev("other", { orderId: "o9" }),
    ]);
    const seen: string[] = [];
    const send = async (e: PrintEvent): Promise<SendResult> => {
      seen.push(e.ref);
      return e.billClientRef === "c1" ? { ok: false, error: "not yet", notSynced: true } : { ok: true };
    };
    const out = await flushPrintQueue(send, store);
    expect(seen).toEqual(["first", "other"]); // "second" was not even tried: copy 2 must not be logged before copy 1
    expect(store.q.map((e) => e.ref)).toEqual(["first", "second"]);
    expect(out.waiting).toBe(2);

    // the bill syncs: both go through, in order
    seen.length = 0;
    const out2 = await flushPrintQueue(async (e) => (seen.push(e.ref), { ok: true }), store);
    expect(seen).toEqual(["first", "second"]);
    expect(store.q).toEqual([]);
    expect(out2.sent).toBe(2);
  });

  it("no connection: stops and keeps everything", async () => {
    const store = memory([ev("a"), ev("b")]);
    const out = await flushPrintQueue(async () => {
      throw new Error("offline");
    }, store);
    expect(out.offline).toBe(true);
    expect(store.q).toHaveLength(2);
  });

  it("a print waiting for a PIN is not retried by itself and holds back its bill", async () => {
    const store = memory([ev("a", { orderId: "o1", needs_approval: true }), ev("b", { orderId: "o1", isReprint: true }), ev("c", { orderId: "o2" })]);
    const seen: string[] = [];
    const out = await flushPrintQueue(async (e) => (seen.push(e.ref), { ok: true }), store);
    expect(seen).toEqual(["c"]);
    expect(out.needsApproval).toBe(1);
    expect(store.q.map((e) => e.ref)).toEqual(["a", "b"]);
  });

  it("a print added while sending is not lost", async () => {
    const store = memory([ev("a")]);
    await flushPrintQueue(async () => {
      store.q = [...store.q, ev("late")];
      return { ok: true };
    }, store);
    expect(store.q.map((e) => e.ref)).toEqual(["late"]);
  });

  it("retryApproved sends one parked print once the PIN was entered", async () => {
    const store = memory([ev("a", { orderId: "o1", needs_approval: true })]);
    const ok = await retryApproved("a", async () => ({ ok: true }), store);
    expect(ok).toBe(true);
    expect(store.q).toEqual([]);
  });
});

describe("recordDeclaredPrint (Ctrl+P)", () => {
  const base = { kind: "bill" as const, orderId: "o1", isReprint: false };

  it("recorded: nothing is queued", async () => {
    const store = memory();
    const out = await recordDeclaredPrint(base, async () => ({ ok: true, reprint: false, printNo: 1 }), store, "r1");
    expect(out).toEqual({ status: "recorded", reprint: false, printNo: 1 });
    expect(store.q).toEqual([]);
  });

  it("declared prints carry the declared flag and the reprint hint when queued", async () => {
    const store = memory();
    const out = await recordDeclaredPrint({ ...base, isReprint: true }, async () => { throw new Error("offline"); }, store, "r1", () => new Date("2026-10-26T10:00:00Z"));
    expect(out).toEqual({ status: "offline", ref: "r1" });
    expect(store.q[0]).toMatchObject({ ref: "r1", declared: true, isReprint: true, kind: "bill", orderId: "o1", at: "2026-10-26T10:00:00.000Z" });
  });

  it("without the right: queued as waiting for a PIN, so the print is never silently lost", async () => {
    const store = memory();
    const out = await recordDeclaredPrint(base, async () => ({ ok: false, error: "You are not allowed to reprint (order.reprint)" }), store, "r1");
    expect(out.status).toBe("needs_approval");
    expect(store.q[0].needs_approval).toBe(true);
  });

  it("other refusals are queued for a few retries", async () => {
    const store = memory();
    const out = await recordDeclaredPrint(base, async () => ({ ok: false, error: "Bill not found." }), store, "r1");
    expect(out.status).toBe("failed");
    expect(store.q[0].needs_approval).toBeUndefined();
  });

  it("the same ref is queued only once", async () => {
    const store = memory();
    const send = async () => ({ ok: false as const, error: "Bill not found." });
    await recordDeclaredPrint(base, send, store, "r1");
    await recordDeclaredPrint(base, send, store, "r1");
    expect(store.q).toHaveLength(1);
  });
});
