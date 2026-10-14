import { describe, expect, it } from "vitest";
import { applySyncOutcome, retryStuck, MAX_REFUSALS } from "../offline-queue";
import type { OfflineBill } from "../offline";

const bill = (id: string, extra: Partial<OfflineBill> = {}): OfflineBill => ({ client_id: id, number: "B-" + id, ...extra }) as OfflineBill;

describe("offline queue: one bad bill must not block the rest", () => {
  it("a sent bill leaves the queue", () => {
    const o = applySyncOutcome([bill("a"), bill("b")], [], bill("a"), { ok: true });
    expect(o.queue.map((b) => b.client_id)).toEqual(["b"]);
    expect(o.stop).toBe(false);
  });

  it("a refused bill is counted, kept, and the run carries on", () => {
    const o = applySyncOutcome([bill("a"), bill("b")], [], bill("a"), { ok: false, refused: true, error: "Bill number X is already used." });
    expect(o.stop).toBe(false);
    expect(o.moved).toBe(false);
    expect(o.queue).toHaveLength(2);
    expect(o.queue[0].sync_tries).toBe(1);
    expect(o.queue[0].sync_error).toMatch(/already used/);
  });

  it(`after ${MAX_REFUSALS} refusals the bill moves to the stuck list and the others still go`, () => {
    let queue = [bill("bad"), bill("good")];
    let stuck: OfflineBill[] = [];
    for (let i = 0; i < MAX_REFUSALS; i++) {
      const o = applySyncOutcome(queue, stuck, queue.find((b) => b.client_id === "bad") ?? bill("bad"), { ok: false, refused: true, error: "An item on offline bill no longer exists." });
      queue = o.queue;
      stuck = o.stuck;
      expect(o.stop).toBe(false);
    }
    expect(queue.map((b) => b.client_id)).toEqual(["good"]);
    expect(stuck.map((b) => b.client_id)).toEqual(["bad"]);
    expect(stuck[0].sync_error).toMatch(/no longer exists/);
    const o = applySyncOutcome(queue, stuck, bill("good"), { ok: true });
    expect(o.queue).toEqual([]);
    expect(o.stuck).toHaveLength(1);
  });

  it("no internet / no open shift stops the run and changes nothing", () => {
    const q = [bill("a"), bill("b")];
    const o = applySyncOutcome(q, [], bill("a"), { ok: false, waiting: true, error: "Open a shift to send offline bills." });
    expect(o.stop).toBe(true);
    expect(o.queue).toEqual(q);
    const o2 = applySyncOutcome(q, [], bill("a"), { ok: false, error: "fetch failed" });
    expect(o2.stop).toBe(true);
    expect(o2.queue).toEqual(q);
  });

  it("guest details pending keeps the bill and counts the try", () => {
    const o = applySyncOutcome([bill("a")], [], bill("a"), { ok: false, guestPending: true });
    expect(o.queue[0].guest_tries).toBe(1);
    expect(o.stop).toBe(false);
  });

  it("stuck bills can be put back, once, with the counter reset", () => {
    const stuck = [bill("x", { sync_tries: 3, sync_error: "old" })];
    const r = retryStuck([bill("a")], stuck);
    expect(r.stuck).toEqual([]);
    expect(r.queue.map((b) => b.client_id)).toEqual(["a", "x"]);
    expect(r.queue[1].sync_tries).toBe(0);
    expect(retryStuck(r.queue, [bill("x")]).queue).toHaveLength(2);
  });
});
