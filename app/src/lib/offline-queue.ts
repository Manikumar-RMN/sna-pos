/**
 * What to do with an offline bill after the server has answered. Pure, so it can be tested.
 *
 * The rule that matters: a bill the server REFUSES must never hold up the bills behind it. After MAX_REFUSALS
 * it moves to the "stuck" list (kept on the device, never deleted) and the queue carries on. A reply that says
 * nothing about this bill (no internet, no open shift) stops the run, because the next bill would fail the same way.
 */
import type { OfflineBill } from "./offline";
import type { SyncResult } from "@/app/(app)/pos/actions";

export const MAX_REFUSALS = 3;

export type Outcome = { queue: OfflineBill[]; stuck: OfflineBill[]; stop: boolean; moved: boolean };

export function applySyncOutcome(queue: OfflineBill[], stuck: OfflineBill[], bill: OfflineBill, res: SyncResult): Outcome {
  const others = queue.filter((b) => b.client_id !== bill.client_id);
  if (res.ok) return { queue: others, stuck, stop: false, moved: false };
  if (res.guestPending) {
    const q = queue.map((b) => (b.client_id === bill.client_id ? { ...b, guest_tries: (b.guest_tries ?? 0) + 1 } : b));
    return { queue: q, stuck, stop: false, moved: false };
  }
  if (res.refused) {
    const tries = (bill.sync_tries ?? 0) + 1;
    const marked = { ...bill, sync_tries: tries, sync_error: res.error ?? "The server refused this bill." };
    if (tries >= MAX_REFUSALS) {
      return { queue: others, stuck: [...stuck.filter((b) => b.client_id !== bill.client_id), marked], stop: false, moved: true };
    }
    return { queue: queue.map((b) => (b.client_id === bill.client_id ? marked : b)), stuck, stop: false, moved: false };
  }
  return { queue, stuck, stop: true, moved: false };
}

/** Puts stuck bills back in the queue for another go (after the cause was fixed). */
export function retryStuck(queue: OfflineBill[], stuck: OfflineBill[]): { queue: OfflineBill[]; stuck: OfflineBill[] } {
  const have = new Set(queue.map((b) => b.client_id));
  const back = stuck.filter((b) => !have.has(b.client_id)).map((b) => ({ ...b, sync_tries: 0 }));
  return { queue: [...queue, ...back], stuck: [] };
}
