/**
 * "Repeat last order": puts the newest kitchen round of a running bill back into the cart.
 *
 * Only WHAT was ordered is copied: dish, chosen options, quantity, note. Never a price, a tax, a discount or a charge:
 * the cart is filled from today's menu, so the new items are priced as the menu says now. A dish or option that is no longer on
 * the menu is skipped and named. Pure functions; the server action that reads the database is pos/repeat-round.ts.
 */

export type RoundLine = {
  /** product id */
  p: string;
  /** name as it was ordered (only used to say what was skipped) */
  nm: string;
  /** chosen option (modifier) ids, sorted */
  o: string[];
  q: number;
  /** kitchen note */
  n: string;
};

export type RoundTicket = { id: string; created_at: string; status: string };
export type RoundTicketItem = { order_item_id: string; quantity: number; status: string };
export type RoundOrderItem = { id: string; product_id: string; product_name: string; kitchen_note: string | null; cancelled_at: string | null };
export type RoundModifier = { order_item_id: string; modifier_item_id: string | null };

/** Tickets made within this long before the newest one belong to the same round (the same grouping the KOT screen uses). */
export const ROUND_WINDOW_MS = 60_000;

/** The ticket ids of the newest round: not cancelled, made in the minute before the newest ticket. */
export function pickRoundTickets(tickets: RoundTicket[]): string[] {
  const live = tickets.filter((t) => t.status !== "cancelled" && Number.isFinite(Date.parse(t.created_at)));
  if (live.length === 0) return [];
  const newest = Math.max(...live.map((t) => Date.parse(t.created_at)));
  return live.filter((t) => Date.parse(t.created_at) >= newest - ROUND_WINDOW_MS).map((t) => t.id);
}

/**
 * Lines of a round. The quantity is what the kitchen was sent in that round (cancelled kitchen lines and cancelled bill lines are
 * left out). Equal dish + options + note are added together. Packing and other charges are not in the kitchen, so not here.
 */
export function buildRoundLines(items: RoundTicketItem[], orderItems: RoundOrderItem[], modifiers: RoundModifier[]): RoundLine[] {
  const byId = new Map(orderItems.map((o) => [o.id, o]));
  const mods = new Map<string, string[]>();
  for (const m of modifiers) {
    if (!m.modifier_item_id) continue;
    const list = mods.get(m.order_item_id) ?? [];
    list.push(m.modifier_item_id);
    mods.set(m.order_item_id, list);
  }
  const out = new Map<string, RoundLine>();
  for (const ti of items) {
    if (ti.status === "cancelled") continue;
    const oi = byId.get(ti.order_item_id);
    const qty = Number(ti.quantity);
    if (!oi || oi.cancelled_at || !(qty > 0)) continue;
    const o = [...new Set(mods.get(oi.id) ?? [])].sort();
    const n = (oi.kitchen_note ?? "").trim().slice(0, 200);
    const key = `${oi.product_id}|${o.join(",")}|${n}`;
    const cur = out.get(key);
    if (cur) cur.q = Math.round((cur.q + qty) * 1000) / 1000;
    else out.set(key, { p: oi.product_id, nm: oi.product_name, o, q: qty, n });
  }
  return [...out.values()];
}

export type RoundOption = { id: string; name: string; price: number };
export type RoundMenuItem = {
  id: string;
  name: string;
  byWeight?: boolean;
  groups: { options: RoundOption[] }[];
};
export type MappedRoundLine<M extends RoundMenuItem> = { item: M; options: RoundOption[]; qty: number; note: string };
export type RoundSkip = { name: string; why: "not_on_menu" | "option_changed" | "bad_quantity" | "charge" };

/**
 * Maps the round onto today's menu. The item and the options come from the menu (so prices are today's); a line whose dish or
 * option is gone is skipped. The caller turns each mapped line into a cart line with its own key and keeps the cart's rules.
 */
export function mapRoundToMenu<M extends RoundMenuItem>(
  lines: RoundLine[],
  menu: M[],
  packingId: string | null,
): { lines: MappedRoundLine<M>[]; skipped: RoundSkip[]; message: string | null } {
  const mapped: MappedRoundLine<M>[] = [];
  const skipped: RoundSkip[] = [];
  for (const l of lines) {
    if (l.p === packingId) {
      skipped.push({ name: l.nm, why: "charge" });
      continue;
    }
    const item = menu.find((m) => m.id === l.p);
    if (!item) {
      skipped.push({ name: l.nm, why: "not_on_menu" });
      continue;
    }
    const options = item.groups.flatMap((g) => g.options.filter((o) => l.o.includes(o.id)));
    if (options.length !== l.o.length) {
      skipped.push({ name: l.nm, why: "option_changed" });
      continue;
    }
    const okQty = Number.isFinite(l.q) && l.q > 0 && (item.byWeight ? true : Number.isInteger(l.q));
    if (!okQty) {
      skipped.push({ name: l.nm, why: "bad_quantity" });
      continue;
    }
    mapped.push({ item, options, qty: l.q, note: l.n.slice(0, 200) });
  }
  const real = skipped.filter((s) => s.why !== "charge");
  const message =
    real.length === 0
      ? null
      : `${real.length === 1 ? "1 item was" : `${real.length} items were`} not repeated because the menu changed: ${real
          .slice(0, 4)
          .map((s) => s.name)
          .join(", ")}${real.length > 4 ? ", ..." : ""}. Check the list before sending.`;
  return { lines: mapped, skipped, message };
}
