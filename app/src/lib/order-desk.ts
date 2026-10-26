/**
 * Pure helpers for the single order screen at /pos (pos/order-desk.tsx). Nothing here works out money.
 *
 * - which screen a device uses (cookie `sna_screen` = one | classic) and the ONE constant that decides the default;
 * - what the address `/pos?bill=<id>` / `/pos?table=<id>` / legacy `/pos?add=<id>` means;
 * - the guests (covers) rule for dine-in, which is a screen rule only (the database accepts a bill without covers);
 * - the words shown when something needs the internet.
 */

/** Per-device choice, kept in a cookie so the server can pick the screen. */
export const SCREEN_COOKIE = "sna_screen";

export type ScreenMode = "one" | "classic";

/**
 * The screen a device gets until somebody chooses otherwise. The Founder decided the new screen is the main one from the start,
 * so this is "one". Changing this single constant switches every device that has no choice saved.
 */
export const DEFAULT_SCREEN: ScreenMode = "one";

export function parseScreenMode(value: string | null | undefined): ScreenMode {
  return value === "one" || value === "classic" ? value : DEFAULT_SCREEN;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (v: unknown): v is string => typeof v === "string" && UUID.test(v);

export type DeskParams = { bill?: string | string[]; table?: string | string[]; add?: string | string[] };

export type DeskTarget =
  | { kind: "counter" }
  | { kind: "table"; tableId: string }
  | { kind: "bill"; billId: string };

const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);

/**
 * What the address asks for. `?bill=` wins over `?table=`; legacy `?add=<id>` is the same as `?bill=<id>` (redirectTo says
 * where to send the browser so the address is the new one). Anything that is not an id is ignored (counter).
 */
export function resolveDeskTarget(params: DeskParams): { target: DeskTarget; redirectTo: string | null } {
  const bill = first(params.bill);
  const add = first(params.add);
  const table = first(params.table);
  if (isUuid(bill)) return { target: { kind: "bill", billId: bill }, redirectTo: null };
  if (isUuid(add)) return { target: { kind: "bill", billId: add }, redirectTo: deskUrl({ kind: "bill", billId: add }) };
  if (isUuid(table)) return { target: { kind: "table", tableId: table }, redirectTo: null };
  return { target: { kind: "counter" }, redirectTo: null };
}

/** The address for a target. `extra` adds the one-off flags the receipt understands. */
export function deskUrl(target: DeskTarget, extra: { print?: boolean; pay?: "split" } = {}): string {
  const q = new URLSearchParams();
  if (target.kind === "bill") q.set("bill", target.billId);
  if (target.kind === "table") q.set("table", target.tableId);
  if (extra.print) q.set("print", "1");
  if (extra.pay) q.set("pay", extra.pay);
  const s = q.toString();
  return s ? `/pos?${s}` : "/pos";
}

/** Largest number of guests the screen accepts (placeOrder keeps the same limit). */
export const MAX_COVERS = 99;

/** The guests box: whole number 1..99, or null when empty / not valid. */
export function parseCovers(text: string): number | null {
  const t = text.trim();
  if (!/^\d{1,3}$/.test(t)) return null;
  const n = Number(t);
  return n >= 1 && n <= MAX_COVERS ? n : null;
}

/**
 * The guests rule of the order screen: a dine-in bill needs at least 1 guest. UI only. Not asked on takeaway / delivery, when adding
 * to an open bill (it already exists), or without internet (an offline bill is paid at once and carries no guests).
 */
export function coversError(input: { askCovers: boolean; orderType: string; adding: boolean; offline: boolean; text: string }): string | null {
  if (!input.askCovers || input.adding || input.offline || input.orderType !== "dine_in") return null;
  return parseCovers(input.text) === null ? `Enter the number of guests (1 to ${MAX_COVERS}) before you send the order.` : null;
}

/** What needs the internet on the order screen, and the sentence shown when there is none. */
export type NeedsInternet = "add_to_bill" | "tip" | "open_price" | "move_item" | "repeat_round" | "bill_action" | "loyalty_redeem";

export function needsInternetText(what: NeedsInternet): string {
  switch (what) {
    case "add_to_bill":
      return "Adding to an open bill needs the internet. Your items stay here until it is back.";
    case "tip":
      return "Tips need the internet.";
    case "open_price":
      return "Open-priced items need the internet. Ask for the price again when it is back.";
    case "move_item":
      return "Moving an item to another table needs the internet.";
    case "repeat_round":
      return "Repeating the last order needs the internet.";
    case "bill_action":
      return "No internet. Changes to an open bill need the connection.";
    case "loyalty_redeem":
      return "Using points needs internet.";
  }
}

/** Items waiting in the cart that a change of table / bill would throw away. null = nothing to ask. */
export function discardQuestion(itemsInCart: number): string | null {
  if (!(itemsInCart > 0)) return null;
  return `${itemsInCart} item${itemsInCart === 1 ? " has" : "s have"} not been sent yet. Leave this order and lose ${itemsInCart === 1 ? "it" : "them"}?`;
}

/** The key of a desk selection: a new terminal is made for each one. Counter, table or bill. */
export function selectionKey(sel: { kind: "counter" } | { kind: "table"; tableId: string } | { kind: "bill"; billId: string }): string {
  return sel.kind === "counter" ? "counter" : sel.kind === "table" ? `t:${sel.tableId}` : `b:${sel.billId}`;
}

/** How long the cart copy kept for a table switch stays valid (it only has to survive one page change). */
export const DESK_CARRY_MAX_AGE_MS = 2 * 60 * 1000;

/** The kept cart may be restored only on the screen it was made for, once, and while it is fresh. */
export function deskCarryUsable(saved: { to?: unknown; at?: unknown } | null | undefined, destKey: string, now: number): boolean {
  if (!saved || typeof saved !== "object") return false;
  const age = typeof saved.at === "number" ? now - saved.at : NaN;
  return saved.to === destKey && age >= 0 && age < DESK_CARRY_MAX_AGE_MS;
}

/** The short notice after the unsent items followed staff to another table. */
export function movedNotice(label: string): string {
  return `Order moved to ${label}`;
}

/**
 * What happens when staff tap another table (or Counter) while the screen may hold unsent items.
 * - nothing in the cart: just go;
 * - items and internet: go, the items follow (nothing is saved on the server before Send KOT, so nothing is duplicated);
 * - items and no internet: the next screen cannot load, so ask (confirm text), keeping the items if the answer is no.
 */
export type SwitchPlan = { action: "go" } | { action: "carry"; notice: string } | { action: "confirm"; question: string };

export function planSwitch(input: { itemsInCart: number; online: boolean; destLabel: string }): SwitchPlan {
  if (!(input.itemsInCart > 0)) return { action: "go" };
  if (!input.online) return { action: "confirm", question: offlineSwitchQuestion(input.itemsInCart) };
  return { action: "carry", notice: movedNotice(input.destLabel) };
}

/** Asked only without internet: the other table cannot be opened, so the items would be lost if the page reloads. */
export function offlineSwitchQuestion(itemsInCart: number): string {
  const n = itemsInCart;
  return `No internet. ${n} item${n === 1 ? " has" : "s have"} not been sent yet and cannot be moved to another table without the connection. Leave this order and lose ${n === 1 ? "it" : "them"}?`;
}

/** The name of a destination for the notice, e.g. "Table 4" / "Counter". */
export function destinationLabel(sel: { kind: "counter" } | { kind: "table"; number: string } | { kind: "bill"; tableNumber: string | null }): string {
  if (sel.kind === "counter") return "Counter";
  if (sel.kind === "table") return `Table ${sel.number}`;
  return sel.tableNumber ? `Table ${sel.tableNumber}` : "this bill";
}

/** The text shown for an open-priced item's price box, or null when it is fine (> 0, at most 2 decimals, below 100 million). */
export function openPriceError(text: string): string | null {
  const t = text.trim();
  if (!/^\d{1,8}(\.\d{1,2})?$/.test(t)) return "Enter the price as an amount, for example 150 or 99.50.";
  return Number(t) > 0 ? null : "The price must be more than zero.";
}

/** The number to put on the cart line: two decimals. Only call after openPriceError returned null. */
export function openPriceValue(text: string): number {
  return Math.round(Number(text.trim()) * 100) / 100;
}
