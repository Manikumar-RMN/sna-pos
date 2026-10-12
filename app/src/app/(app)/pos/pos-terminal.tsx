"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money, orderTypeLabel, roundCash } from "@/lib/format";
import { UpiQr } from "../upi-qr";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { addToBill, getOfflineSnapshot, placeOrder, quoteOrder, type CartItem, type PlaceOrderInput, type Quote, type Senior } from "./actions";
import { cashDue, deviceKey, offlineQuote, readQueue, readSnapshot, saveSnapshot, takeNumber, writeQueue, type OfflineBill, type Snapshot } from "@/lib/offline";
import { OfflineReceipt } from "./offline-receipt";
import { DishName, Dual } from "../lang";

export type OptionGroup = {
  id: string;
  name: string;
  min: number;
  max: number;
  options: { id: string; name: string; price: number }[];
};
type MenuItem = {
  id: string;
  name: string;
  short_name: string | null;
  price: number;
  category_id: string;
  category_name: string;
  is_veg: boolean | null;
  groups: OptionGroup[];
  /** Dish name in the restaurant's second language. */
  name_local?: string | null;
};
type PaymentMethod = { id: string; name: string; kind: string; ask_reference: boolean; upi_id?: string | null };
type Table = { id: string; number: string; busy: boolean; /** Unpaid and part-paid bills on this table, oldest first. */ openBills: { id: string; billNumber: string }[] };
type OrderType = "dine_in" | "takeaway" | "delivery";
/**
 * The outlet's packing charge (Settings). It is an ordinary menu item that is
 * added to the bill by a tick in the cart, never by tapping it on the menu.
 */
export type PackingRule = {
  productId: string;
  /** Price of one. */
  price: number;
  /** Charged once per bill, or once for every item on it. */
  per: "bill" | "item";
  /** Ticked by default on takeaway / delivery bills. */
  takeaway: boolean;
  delivery: boolean;
};
type ChosenOption = { id: string; name: string; price: number };
type CartLine = { key: string; item: MenuItem; qty: number; options: ChosenOption[]; note: string; hold?: boolean };

/** One-tap kitchen notes; staff can also type their own. */
const QUICK_NOTES = ["No onion", "No garlic", "Less spicy", "Extra spicy", "Less oil", "Parcel"];
/** The optional guest boxes are smaller than the usual input so they do not push the bill down. */
const GUEST_FIELD = { minHeight: 40, padding: "0 12px" } as const;
export type AddTo = { id: string; billNumber: string; table: string | null };

function lineKey(productId: string, options: ChosenOption[]) {
  return productId + "|" + options.map((o) => o.id).sort().join(",");
}
function unitPrice(l: { item: MenuItem; options: ChosenOption[] }) {
  return Math.round((l.item.price + l.options.reduce((s, o) => s + o.price, 0)) * 100) / 100;
}
/**
 * "Add to this bill" opens this screen again for that bill, which starts it empty. The items already
 * in the cart travel in this tab's sessionStorage: only what was chosen (item, options, quantity,
 * note, hold) — never a price, the packing charge, guest details, discount or payment.
 */
const CARRY_KEY = "sna.pos.carry.v1";
const CARRY_MAX_AGE_MS = 2 * 60 * 1000;
type CarriedLine = { p: string; o: string[]; q: number; n: string; h: boolean };
/**
 * Reads the carried items for this bill, once (the saved copy is removed). Null: nothing usable was saved.
 * Names and prices come from today's menu; a line whose item or option is no longer on it is left out and counted.
 */
function takeCarried(billId: string, menu: MenuItem[], packingId: string | null, allowHold: boolean): { cart: Record<string, CartLine>; dropped: number } | null {
  let raw: string | null;
  try {
    raw = sessionStorage.getItem(CARRY_KEY);
    sessionStorage.removeItem(CARRY_KEY);
  } catch {
    return null;
  }
  if (!raw) return null;
  let saved: { bill?: unknown; at?: unknown; lines?: unknown } | null;
  try {
    saved = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!saved || typeof saved !== "object") return null;
  const age = typeof saved.at === "number" ? Date.now() - saved.at : NaN;
  if (saved.bill !== billId || !(age >= 0 && age < CARRY_MAX_AGE_MS) || !Array.isArray(saved.lines)) return null;
  const cart: Record<string, CartLine> = {};
  let dropped = 0;
  saved.lines.forEach((x: unknown, i: number) => {
    const l = (x && typeof x === "object" ? x : {}) as { [K in keyof CarriedLine]?: unknown };
    const item = menu.find((it) => it.id === l.p && it.id !== packingId);
    const ids = Array.isArray(l.o) ? [...new Set<unknown>(l.o)] : null;
    const qty = l.q;
    // The chosen options, as today's menu has them and in the order the option picker gives them.
    const options: ChosenOption[] = item && ids ? item.groups.flatMap((g) => g.options.filter((o) => ids.includes(o.id))) : [];
    if (!item || !ids || options.length !== ids.length || typeof qty !== "number" || !Number.isInteger(qty) || qty < 1) {
      dropped++;
      return;
    }
    const base = lineKey(item.id, options);
    const key = cart[base] ? `${base}#c${i}` : base;
    const line: CartLine = { key, item, options, qty, note: typeof l.n === "string" ? l.n.slice(0, 200) : "" };
    if (allowHold && l.h === true) line.hold = true;
    cart[key] = line;
  });
  return { cart, dropped };
}
/** The packing charge rule kept in this device's offline copy (null: none, or its menu item is not in the copy). */
function offlinePackingRule(snap: Snapshot | null): PackingRule | null {
  const rule = snap?.settings.packing;
  const item = rule ? snap.menu.find((x) => x.id === rule.product_id) : undefined;
  if (!rule || !item) return null;
  return { productId: item.id, price: Number(item.price), per: rule.per === "item" ? "item" : "bill", takeaway: !!rule.takeaway, delivery: !!rule.delivery };
}

export function PosTerminal({
  currency,
  canDiscount,
  canPay,
  showSenior,
  upiPayee = null,
  pricesIncludeTax,
  taxName,
  menu,
  paymentMethods,
  tables,
  addTo,
  packing = null,
  allowHold = false,
  customerDisplay = null,
  tableOrdersWaiting = 0,
  licenceLockAt = null,
  categoryParents = {},
}: {
  currency: string;
  canDiscount: boolean;
  /** Has the "Take payment" right. Without it the bill is only sent to the kitchen. */
  canPay: boolean;
  /** Philippines: senior citizen / PWD discount. */
  showSenior: boolean;
  /** India: name shown in the customer's UPI app. Null hides the UPI QR. */
  upiPayee?: string | null;
  pricesIncludeTax: boolean;
  taxName: string;
  menu: MenuItem[];
  paymentMethods: PaymentMethod[];
  tables: Table[];
  /** When set, the screen adds items to this open bill instead of making a new one. */
  addTo: AddTo | null;
  /** The outlet's packing charge, or null when it has none. */
  packing?: PackingRule | null;
  /** Professional: hold items for the next course. */
  allowHold?: boolean;
  /** Add-on: a second screen facing the guest shows the order and total. Value = restaurant name. */
  customerDisplay?: string | null;
  /** Add-on: orders sent by guests from the table QR, waiting for staff. */
  tableOrdersWaiting?: number;
  /** The moment this restaurant becomes read-only (licence end), or null. Used when billing without internet. */
  licenceLockAt?: string | null;
  /** Sub-category id → its main category. Main categories are not listed. */
  categoryParents?: Record<string, { id: string; name: string }>;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [cart, setCart] = useState<Record<string, CartLine>>({});
  const [search, setSearch] = useState("");
  /** Category tab; null = All. Not remembered between visits. */
  const [tab, setTab] = useState<string | null>(null);
  /** Sub-category tab inside the chosen main category; null = all of it. */
  const [subTab, setSubTab] = useState<string | null>(null);
  const [orderType, setOrderType] = useState<OrderType>("dine_in");
  const [tableId, setTableId] = useState<string | null>(null);
  /** The cashier chose to start a second bill on a table that already has an open one. */
  const [separateBill, setSeparateBill] = useState(false);
  // Guest details for takeaway and delivery bills. All optional.
  const [guestName, setGuestName] = useState("");
  const [guestPhone, setGuestPhone] = useState("");
  const [guestAddress, setGuestAddress] = useState("");
  /** Packing charge tick: null = not touched, so it follows the order type. */
  const [packingChoice, setPackingChoice] = useState<boolean | null>(null);
  const [methodId, setMethodId] = useState<string>(paymentMethods[0]?.id ?? "");
  const [tendered, setTendered] = useState("");
  const [reference, setReference] = useState("");
  const [discount, setDiscount] = useState("");
  const [discountReason, setDiscountReason] = useState("");
  const [scChoice, setScChoice] = useState<boolean | null>(null);
  const [senior, setSenior] = useState<Senior | null>(null);
  const [seniorOpen, setSeniorOpen] = useState(false);
  const [picking, setPicking] = useState<MenuItem | null>(null);
  const [error, setError] = useState<string | null>(null);
  // "This bill may already be saved": kept apart from the ordinary message, which the next price check wipes.
  // It stays until the bill is saved, cleared or made offline.
  const [maybeSaved, setMaybeSaved] = useState(false);

  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoting, setQuoting] = useState(false);
  const reqId = useRef(0);
  // Offline billing: a copy of the menu and tax rules on this device.
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [offline, setOffline] = useState(false);
  const [offlineBill, setOfflineBill] = useState<OfflineBill | null>(null);
  // After a bill is saved (or items are added) the screen moves on to the bill. Until it has, nothing more may
  // be saved from here: the buttons would otherwise work again for a moment, and a second tap made a second bill.
  // Value = where the screen is going. The ref is the same fact, readable at once by a tap that lands before
  // the screen has drawn again.
  const [saved, setSaved] = useState<string | null>(null);
  const savedRef = useRef(false);
  const [savedSlow, setSavedSlow] = useState(false);
  // A save or an add is on its way to the server right now.
  const sending = useRef(false);

  const m = (n: number) => money(n, currency);
  const lines = Object.values(cart);
  const isCash = paymentMethods.find((p) => p.id === methodId)?.kind === "cash";
  const askRef = !!paymentMethods.find((p) => p.id === methodId)?.ask_reference;
  const discountAmt = Math.max(0, Number(discount) || 0);
  const chosenTable = tables.find((t) => t.id === tableId) ?? null;
  // A table that already has an open bill: the cashier adds to it, or says clearly that a second bill is wanted.
  // (Bills made without internet are paid at once and carry no table, so they are not held back.)
  const needSeparate = !addTo && !offline && orderType === "dine_in" && !!chosenTable && chosenTable.openBills.length > 0 && !separateBill;

  // Packing charge. Without internet the rule and the price come from this device's offline copy.
  const offlinePacking = useMemo(() => offlinePackingRule(snap), [snap]);
  const packRule = offline ? offlinePacking : packing;
  const packingId = packRule?.productId ?? null;
  const packingDefault = !addTo && !!packRule && ((orderType === "takeaway" && packRule.takeaway) || (orderType === "delivery" && packRule.delivery));
  const packingTicked = !!packRule && (packingChoice ?? packingDefault);
  // Per item: one for every item on the bill.
  const packingQty = packRule?.per === "item" ? Math.max(1, Math.ceil(lines.reduce((s, l) => s + l.qty, 0))) : 1;
  const packingAmount = packRule ? Math.round(packRule.price * packingQty * 100) / 100 : 0;

  // Category tabs, in menu order: main categories; a sub-category's dishes come under its main one.
  // The packing charge is not sold from the menu.
  const tabs = useMemo(() => {
    const out: { id: string; name: string }[] = [];
    for (const x of menu) {
      if (x.id === packingId) continue;
      const m = categoryParents[x.category_id] ?? { id: x.category_id, name: x.category_name };
      if (!out.some((c) => c.id === m.id)) out.push(m);
    }
    return out;
  }, [menu, packingId, categoryParents]);
  const activeTab = tab !== null && tabs.some((c) => c.id === tab) ? tab : null;
  // The chosen main category's sub-categories (only those with dishes on sale).
  const subTabs = useMemo(() => {
    if (activeTab === null) return [];
    const out: { id: string; name: string }[] = [];
    for (const x of menu)
      if (x.id !== packingId && categoryParents[x.category_id]?.id === activeTab && !out.some((c) => c.id === x.category_id))
        out.push({ id: x.category_id, name: x.category_name });
    return out;
  }, [menu, packingId, categoryParents, activeTab]);
  const activeSub = subTab !== null && subTabs.some((c) => c.id === subTab) ? subTab : null;
  const searching = search.trim() !== "";

  const categories = useMemo(() => {
    // A search looks in every category; otherwise the chosen tab (and sub-category tab) decides.
    const q = search.trim().toLowerCase();
    const filtered = menu.filter((x) => {
      if (x.id === packingId) return false;
      if (q) return x.name.toLowerCase().includes(q) || (x.short_name ?? "").toLowerCase().includes(q);
      if (activeTab === null) return true;
      const main = categoryParents[x.category_id]?.id ?? x.category_id;
      return main === activeTab && (activeSub === null || x.category_id === activeSub);
    });
    const groups: { id: string; name: string; items: MenuItem[] }[] = [];
    for (const x of filtered) {
      let g = groups.find((y) => y.id === x.category_id);
      if (!g) {
        const parent = categoryParents[x.category_id];
        // Inside its own main category the sub-category's name is enough.
        const name = parent && activeTab !== parent.id ? `${parent.name} › ${x.category_name}` : x.category_name;
        g = { id: x.category_id, name, items: [] };
        groups.push(g);
      }
      g.items.push(x);
    }
    return groups;
  }, [menu, search, activeTab, activeSub, packingId, categoryParents]);

  const qtyInCart = (productId: string) => lines.filter((l) => l.item.id === productId).reduce((s, l) => s + l.qty, 0);
  // The same list goes to the live total and to the saved bill, so the two always agree.
  // The packing charge, when ticked, is one more item at the end: no note, no options, never held.
  const itemsPayload = () => {
    const items: CartItem[] = lines.map((l) => ({ product_id: l.item.id, qty: l.qty, options: l.options.map((o) => o.id), note: l.note.trim() || undefined, hold: !!l.hold }));
    if (packRule && packingTicked && lines.length > 0) items.push({ product_id: packRule.productId, qty: packingQty });
    return items;
  };
  /** The same list for the offline calculation. */
  const offlineLines = () => {
    const out = lines.map((l) => ({ product_id: l.item.id, qty: l.qty, unit_price: unitPrice(l) }));
    if (packRule && packingTicked && lines.length > 0) out.push({ product_id: packRule.productId, qty: packingQty, unit_price: packRule.price });
    return out;
  };

  // Ask the database for the exact bill whenever the cart changes (new bills only).
  // Replies that arrive out of order are ignored.
  const cartKey = JSON.stringify([lines.map((l) => [l.key, l.qty]), discountAmt, scChoice, senior, packingTicked ? packingId : null]);
  const [noteOpen, setNoteOpen] = useState<string | null>(null);
  const [approval, setApproval] = useState<null | { permission: string; retry: () => void }>(null);
  // New bills: the id sent with a bill belongs to exactly what was submitted. The identical submission again
  // (double tap, "internet dropped, press again", the retry after a manager's PIN) sends the same id, so the
  // server answers with the bill it already saved. Anything different gets a new id, so a different bill can
  // never be answered with an older one. Forgotten when the bill is saved, cleared, emptied or made offline.
  const billRef = useRef<{ key: string; id: string } | null>(null);
  // Adding to an open bill: the same id while the same items are retried, a new one when they change or after they are added.
  const addRef = useRef<{ key: string; id: string } | null>(null);

  useEffect(() => {
    const cached = readSnapshot();
    if (cached) setSnap(cached);
    setOffline(!navigator.onLine);
    const on = () => setOffline(false);
    const off = () => setOffline(true);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    if (navigator.onLine) {
      getOfflineSnapshot(deviceKey())
        .then((r) => {
          if (r.ok) {
            saveSnapshot(r.snapshot as Snapshot);
            setSnap(r.snapshot as Snapshot);
          }
        })
        .catch(() => setOffline(true));
    }
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
    };
  }, []);

  // "Offline" is also switched on when a call to the server fails although the device says it has internet
  // (the server hiccuped, or the Wi-Fi is up but the line behind it is down). The browser never announces the
  // end of that, so ask the server quietly every few seconds and go back to normal as soon as it answers.
  const cameBack = useRef({ at: 0, times: 0 });
  /** The device has internet, yet the server has not answered several times in a row. */
  const [stuck, setStuck] = useState(false);
  useEffect(() => {
    if (!offline) return;
    // If "back to normal" keeps failing straight away (the server answers this question but not the billing
    // ones), ask less and less often, so the screen does not flicker between the two states.
    const b = cameBack.current;
    b.times = Date.now() - b.at < 60000 ? b.times + 1 : 0;
    const wait = Math.min(60000, 4000 * 2 ** b.times);
    let stopped = false;
    let asking = false;
    let failed = 0;
    const ask = async () => {
      if (stopped || asking || !navigator.onLine) return;
      asking = true;
      try {
        // Ten seconds at most: a question that never comes back must not be the last one asked.
        const r = await Promise.race([
          getOfflineSnapshot(deviceKey()),
          new Promise<never>((_, no) => setTimeout(() => no(new Error("no answer")), 10000)),
        ]);
        if (stopped) return;
        // Any answer at all, even a refusal, means the server can be reached again.
        if (r.ok) {
          saveSnapshot(r.snapshot as Snapshot);
          setSnap(r.snapshot as Snapshot);
        }
        cameBack.current.at = Date.now();
        setStuck(false);
        setOffline(false);
      } catch {
        // Still no answer: stay offline and ask again later. After a few tries with the device itself
        // online, the likeliest cause is that this screen is older than the system (it was updated): say so.
        if (++failed >= 3 && navigator.onLine && !stopped) setStuck(true);
      } finally {
        asking = false;
      }
    };
    const first = setTimeout(ask, wait);
    const again = setInterval(ask, Math.max(15000, wait));
    const seen = () => {
      if (document.visibilityState === "visible") ask();
    };
    document.addEventListener("visibilitychange", seen);
    return () => {
      stopped = true;
      clearTimeout(first);
      clearInterval(again);
      document.removeEventListener("visibilitychange", seen);
      setStuck(false);
    };
  }, [offline]);

  // Should this screen ever be shown again with what it held before (a browser keeping the page alive), a
  // lock left over from a bill that was already saved must not greet the next guest.
  useEffect(() => {
    if (!savedRef.current) return;
    savedRef.current = false;
    setSaved(null);
    clearAll();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // The bill is saved and the screen is on its way to it. If that takes long (a slow line), offer the way by hand.
  useEffect(() => {
    if (!saved) return setSavedSlow(false);
    const t = setTimeout(() => setSavedSlow(true), 6000);
    return () => clearTimeout(t);
  }, [saved]);

  function localQuote(): Quote | string {
    if (!snap) return "No internet, and this device has no offline copy of the menu yet. Open Billing once while online.";
    if (senior) return "The senior citizen / PWD discount needs the internet.";
    try {
      const c = offlineQuote(snap, offlineLines(), snap.rights.discount ? discountAmt : 0, scChoice);
      const scOn = (scChoice ?? snap.settings.sc_default_on) && snap.settings.sc_percent > 0;
      return {
        subtotal: c.subtotal,
        discount: c.discount,
        senior_discount: 0,
        tax_exempt_amount: 0,
        service_charge: c.service_charge,
        tax_total: c.tax_total,
        tax_included: c.tax_included,
        rounding: c.rounding,
        grand_total: c.grand_total,
        taxes: c.taxes.map((t) => ({ name: t.name, rate: t.rate, amount: t.amount })),
        lines: c.lines.map((l) => ({ key: l.key, total: l.total })),
        service_charge_available: snap.settings.sc_percent > 0,
        service_charge_on: scOn,
        service_charge_percent: snap.settings.sc_percent,
        service_charge_label: snap.settings.sc_label,
        cash_rounding: snap.settings.cash_rounding,
      };
    } catch (e) {
      return (e as Error).message;
    }
  }
  useEffect(() => {
    if (addTo || lines.length === 0) {
      // A reply still on its way for the cart as it was must not put its total back.
      reqId.current++;
      setQuote(null);
      setQuoting(false);
      return;
    }
    const id = ++reqId.current;
    setQuoting(true);
    const t = setTimeout(async () => {
      let res: Awaited<ReturnType<typeof quoteOrder>>;
      const fromDevice = () => {
        const q = localQuote();
        return typeof q === "string" ? ({ ok: false, error: q } as const) : ({ ok: true, quote: q } as const);
      };
      if (offline) res = fromDevice();
      else {
        try {
          res = await quoteOrder({ items: itemsPayload(), discount_amount: discountAmt, service_charge: scChoice, senior });
        } catch {
          setOffline(true);
          res = fromDevice();
        }
      }
      if (id !== reqId.current) return;
      setQuoting(false);
      if (res.ok) {
        setQuote(res.quote);
        setError(null);
      } else {
        setQuote(null);
        setError(res.error);
      }
    }, 250);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cartKey, offline, snap]);

  // Customer display (a second window on the guest-facing screen) follows the cart and the total.
  useEffect(() => {
    if (!customerDisplay || typeof BroadcastChannel === "undefined") return;
    const ch = new BroadcastChannel("sna-customer-display");
    ch.postMessage({
      restaurant: customerDisplay,
      currency,
      lines: [
        ...Object.values(cart).map((l) => ({
          name: l.item.name,
          local: l.item.name_local ?? null,
          options: l.options.map((o) => o.name).join(", ") || null,
          qty: l.qty,
          amount: Math.round(unitPrice(l) * l.qty * 100) / 100,
        })),
        ...(packingTicked && Object.keys(cart).length ? [{ name: "Packing charge", local: null, options: null, qty: packingQty, amount: packingAmount }] : []),
      ],
      total: quote && Object.keys(cart).length ? quote.grand_total : null,
    });
    ch.close();
  }, [cart, quote, customerDisplay, currency, packingTicked, packingQty, packingAmount]);

  const due = quote ? (isCash ? roundCash(quote.grand_total, quote.cash_rounding) : quote.grand_total) : 0;
  const cashRound = quote && isCash ? Math.round((due - quote.grand_total) * 100) / 100 : 0;
  const change = isCash && Number(tendered) > due ? Math.round((Number(tendered) - due) * 100) / 100 : 0;
  const addedTax = quote ? Math.round((quote.tax_total - quote.tax_included) * 100) / 100 : 0;
  const addSubtotal = Math.round((lines.reduce((s, l) => s + unitPrice(l) * l.qty, 0) + (packingTicked && lines.length > 0 ? packingAmount : 0)) * 100) / 100;

  function tapItem(item: MenuItem) {
    // Saved and on the way to the bill: taps now would only be lost.
    if (savedRef.current) return;
    setError(null);
    if (item.groups.length > 0) setPicking(item);
    else addLine(item, []);
  }
  function addLine(item: MenuItem, options: ChosenOption[]) {
    const base = lineKey(item.id, options);
    setCart((c) => {
      // Same item again goes onto the line without a note; a line with a kitchen
      // note ("no onion") stays separate so the kitchen sees exactly which one.
      const plain = Object.values(c).find((l) => l.key.split("#")[0] === base && l.note.trim() === "" && !l.hold);
      if (plain) return { ...c, [plain.key]: { ...plain, qty: plain.qty + 1 } };
      const key = c[base] ? `${base}#${Date.now()}` : base;
      return { ...c, [key]: { key, item, options, qty: 1, note: "" } };
    });
  }
  function toggleHold(key: string) {
    setCart((c) => (c[key] ? { ...c, [key]: { ...c[key], hold: !c[key].hold } } : c));
  }
  function setNote(key: string, note: string) {
    setCart((c) => (c[key] ? { ...c, [key]: { ...c[key], note: note.slice(0, 200) } } : c));
  }
  function step(key: string, delta: number) {
    if (savedRef.current) return;
    setCart((c) => {
      const cur = c[key];
      if (!cur) return c;
      const qty = cur.qty + delta;
      if (qty <= 0) {
        const rest = { ...c };
        delete rest[key];
        return rest;
      }
      return { ...c, [key]: { ...cur, qty } };
    });
  }
  function clearAll() {
    setCart({});
    // The search goes too; the chosen category tab stays.
    setSearch("");
    resetBill();
  }
  /** Everything that belongs to one bill, apart from its items. The order type, category tab and payment method stay. */
  function resetBill() {
    billRef.current = null;
    setDiscount("");
    setDiscountReason("");
    setTendered("");
    setReference("");
    setTableId(null);
    setSeparateBill(false);
    setGuestName("");
    setGuestPhone("");
    setGuestAddress("");
    setPackingChoice(null);
    setScChoice(null);
    setSenior(null);
    setError(null);
    setMaybeSaved(false);
  }
  // A bill emptied line by line ("−" on the last item) is over just as one that is cleared: nothing of it may
  // stay for the next guest. Only the change from "has items" to "empty" counts, so a guest name typed before
  // the first item is added is kept.
  const hadLines = useRef(false);
  useEffect(() => {
    if (hadLines.current && lines.length === 0) resetBill();
    hadLines.current = lines.length > 0;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lines.length]);

  // Add mode: pick up the items carried over from the billing screen ("Add to this bill"), once.
  useEffect(() => {
    if (!addTo) return;
    const carried = takeCarried(addTo.id, menu, packing?.productId ?? null, allowHold);
    if (!carried) return;
    if (Object.keys(carried.cart).length > 0) setCart((c) => (Object.keys(c).length > 0 ? c : carried.cart));
    if (carried.dropped > 0) setError(`${carried.dropped} item${carried.dropped === 1 ? "" : "s"} could not be brought over because the menu changed. Check the list before adding.`);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /** Opens this screen for an open bill, taking the items already in the cart along. */
  function openAddTo(billId: string) {
    // Not while this bill is being saved or has just been saved: its items would be carried onto the other bill as well.
    if (savedRef.current || sending.current) return;
    try {
      if (lines.length > 0) {
        const carried: CarriedLine[] = lines.map((l) => ({ p: l.item.id, o: l.options.map((o) => o.id), q: l.qty, n: l.note, h: !!l.hold }));
        sessionStorage.setItem(CARRY_KEY, JSON.stringify({ bill: billId, at: Date.now(), lines: carried }));
      } else sessionStorage.removeItem(CARRY_KEY);
    } catch {
      // No storage on this device: the screen opens with an empty cart, as before.
    }
    router.push(`/pos?add=${billId}`);
  }
  function chooseOrderType(t: OrderType) {
    // Another kind of bill: the packing tick follows that kind again, whatever was ticked by hand before.
    if (t !== orderType) setPackingChoice(null);
    setOrderType(t);
  }
  function chooseTable(id: string | null) {
    setTableId(id);
    // A new table is a new question: is a second bill really wanted here?
    setSeparateBill(false);
  }

  function submitOffline(mode: "pay" | "unpaid" | "split") {
    // The licence ended while this device was without internet: the server would refuse the bill, so it is not made.
    if (licenceLockAt && Date.now() >= Date.parse(licenceLockAt)) {
      return setError("The SNA POS licence for this restaurant has ended, so new bills cannot be made. Please contact SNA to renew.");
    }
    if (!snap || !quote) return setError("No internet, and this device has no offline copy of the menu yet.");
    if (mode !== "pay") return setError("Without internet only paid bills can be made. Take the payment now.");
    if (!canPay) return setError("Without internet only the cashier can make bills here.");
    const method = paymentMethods.find((p) => p.id === methodId);
    if (!method) return setError("Choose how the customer paid.");
    const byId = new Map(snap.menu.map((m) => [m.id, m]));
    const missing = lines.find((l) => !byId.has(l.item.id));
    if (missing) return setError(`${missing.item.name} is not in this device's offline menu. Remove it or wait for the internet.`);
    const calc = offlineQuote(snap, offlineLines(), snap.rights.discount ? discountAmt : 0, scChoice);
    const dueNow = cashDue(snap, calc.grand_total, method.kind === "cash");
    if (method.kind === "cash" && tendered !== "" && Number(tendered) < dueNow) return setError("Amount received is less than the total.");
    // Guest details typed before or after the internet dropped go with the bill, as they do online: none on
    // dine-in, an address only on delivery. The phone is checked here the way the server will check it later.
    const guest =
      orderType === "dine_in" ? null : { name: guestName.trim(), phone: guestPhone.trim(), address: orderType === "delivery" ? guestAddress.trim() : "" };
    if (guest?.phone && guest.phone.replace(/\D/g, "").length < 7) return setError("That phone number looks too short.");
    const { seq, number } = takeNumber(snap);
    const bill: OfflineBill = {
      client_id: crypto.randomUUID(),
      device_key: snap.device_key,
      seq,
      fy: snap.series.fy,
      number,
      created_at: new Date().toISOString(),
      order_type: orderType,
      guest: guest && (guest.name || guest.phone || guest.address) ? guest : null,
      items: [
        ...lines.map((l) => ({
          product_id: l.item.id,
          name: l.item.name,
          qty: l.qty,
          price: unitPrice(l),
          options: l.options.map((o) => o.id),
          options_text: l.options.map((o) => o.name).join(", ") || null,
          note: l.note.trim() || undefined,
          station: byId.get(l.item.id)?.station ?? "Kitchen",
        })),
        // The packing charge is the last line, as in the calculation above, so the server records it when the bill is sent.
        ...(packRule && packingTicked
          ? [
              {
                product_id: packRule.productId,
                name: byId.get(packRule.productId)?.name ?? "Packing charge",
                qty: packingQty,
                price: packRule.price,
                options: [],
                options_text: null,
                station: byId.get(packRule.productId)?.station ?? "Kitchen",
              },
            ]
          : []),
      ],
      discount: snap.rights.discount ? discountAmt : 0,
      service_charge: (scChoice ?? snap.settings.sc_default_on) && snap.settings.sc_percent > 0,
      method_id: method.id,
      method_name: method.name,
      tendered: method.kind === "cash" && tendered !== "" ? Number(tendered) : null,
      reference: askRef ? reference : null,
      grand_total: calc.grand_total,
      due: dueNow,
      calc,
    };
    const q = readQueue();
    if (!writeQueue([...q, bill])) return setError("This device's storage is full, so the bill could not be saved. Free some space.");
    window.dispatchEvent(new Event("sna-offline-queue"));
    // This guest now has an offline bill; whatever is billed next is another bill.
    billRef.current = null;
    setMaybeSaved(false);
    setOfflineBill(bill);
  }

  function submit(mode: "pay" | "unpaid" | "split") {
    // Already saved and on the way to the bill, an offline bill is showing, or a save is still on its way: one tap, one bill.
    if (savedRef.current || offlineBill || sending.current) return;
    setError(null);
    if (lines.length === 0) return setError("Add at least one item.");
    if (!quote || quoting) return setError("Please wait a moment — the total is being checked.");
    if (needSeparate) return setError(`Table ${chosenTable?.number ?? ""} already has an open bill. Add to it, or tick “Start a separate bill for this table”.`);
    if (offline) return submitOffline(mode);
    const payNow = mode === "pay";
    if (payNow && !methodId) return setError("Choose how the customer paid.");
    if (payNow && isCash && tendered !== "" && Number(tendered) < due) return setError("Amount received is less than the total.");

    const input: Omit<PlaceOrderInput, "client_ref"> = {
      items: itemsPayload(),
      discount_amount: senior ? 0 : discountAmt,
      service_charge: scChoice,
      senior,
      order_type: orderType,
      table_id: orderType === "dine_in" ? tableId : null,
      payment_method_id: payNow ? methodId : null,
      tendered: payNow && isCash && tendered !== "" ? Number(tendered) : null,
      discount_reason: discountAmt > 0 ? discountReason.trim() || null : null,
      reference: payNow && askRef ? reference : null,
      // Only what the cashier can see is sent: no guest details on dine-in, an address only on delivery.
      guest: orderType === "dine_in" ? null : { name: guestName, phone: guestPhone, address: orderType === "delivery" ? guestAddress : "" },
    };
    // The same submission keeps its id; any difference at all (items, table, guest, discount, payment…) makes a new one.
    // Known limit, not solvable from the browser: if an attempt did reach the server but its reply was lost, and the
    // cashier then changes anything before pressing again (for example pays by another method), that is a new id and
    // the server saves a second bill. Hence the "check Bills" message below.
    const key = JSON.stringify(input);
    if (billRef.current?.key !== key) billRef.current = { key, id: crypto.randomUUID() };
    const ref = billRef.current.id;
    sending.current = true;
    startTransition(async () => {
      let res: Awaited<ReturnType<typeof placeOrder>>;
      try {
        res = await placeOrder({ ...input, client_ref: ref });
      } catch {
        // The internet dropped while saving. No reply came back, so the id is kept: pressing again
        // with nothing changed is safe; meanwhile the bill can be made offline.
        sending.current = false;
        setOffline(true);
        return setMaybeSaved(true);
      }
      sending.current = false;
      if (!res.ok) {
        const need = neededRight(res.error);
        if (need) setApproval({ permission: need, retry: () => submit(mode) });
        return setError(cleanMessage(res.error));
      }
      // Saved. The screen is locked until it has moved on to the bill; the id is kept on purpose, so that even
      // a tap that slipped through would be answered with this same bill and not make another.
      // KOT (saved unpaid): print the kitchen ticket and go on to the next order; the bill is paid later.
      const next =
        mode === "split" ? `/bills/${res.orderId}?pay=split` : mode === "unpaid" ? `/pos/kot/${res.orderId}` : `/pos/receipt/${res.orderId}?print=1`;
      savedRef.current = true;
      setMaybeSaved(false);
      setSaved(next);
      router.push(next);
    });
  }

  /** Only when the saved bill did not open by itself: leave it (it is in Bills) and start the next one. */
  function startNextBill() {
    savedRef.current = false;
    setSaved(null);
    clearAll();
    // Going to this same screen again takes the place of the move to the saved bill that is still on its
    // way, so it cannot arrive later and sweep away the next guest's items.
    router.replace("/pos");
  }

  function submitAdd() {
    if (!addTo || savedRef.current || sending.current) return;
    setError(null);
    if (offline) return setError("Adding to an open bill needs the internet.");
    if (lines.length === 0) return setError("Add at least one item.");
    const items = itemsPayload();
    const key = JSON.stringify(items);
    if (addRef.current?.key !== key) addRef.current = { key, id: crypto.randomUUID() };
    const ref = addRef.current.id;
    sending.current = true;
    startTransition(async () => {
      let res: Awaited<ReturnType<typeof addToBill>>;
      try {
        res = await addToBill(addTo.id, items, ref);
      } catch {
        // No reply from the server. The same request id makes pressing the button again safe.
        sending.current = false;
        return setError("The internet dropped while adding. Press the button again — the items will not be added twice.");
      }
      sending.current = false;
      if (!res.ok) return setError(res.error);
      // Added. Locked until the bill opens; the id is kept so that a tap that slipped through adds nothing twice.
      savedRef.current = true;
      // The added items go to the kitchen: print their KOT here, then back to the bill.
      setSaved(`/pos/kot/${addTo.id}?then=bill`);
      router.push(`/pos/kot/${addTo.id}?then=bill`);
    });
  }

  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_360px]">
      <div>
        <div className="mb-3 flex flex-wrap items-center gap-x-3">
          <h1 className="text-xl font-bold tracking-tight">{addTo ? `Add items to bill ${addTo.billNumber}` : "Billing"}</h1>
          {offline && (
            <span className="rounded-full px-2.5 py-0.5 text-[11px] font-bold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
              OFFLINE — paid bills only
            </span>
          )}
          {offline && stuck && !saved && (
            <span className="flex flex-wrap items-center gap-2 text-xs" style={{ color: "var(--color-ink-2)" }}>
              This device has internet but the server is not answering this screen.
              <button
                type="button"
                className="min-h-9 rounded-lg border px-3 font-bold"
                style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}
                onClick={() => window.location.reload()}
              >
                Reload the screen
              </button>
              {lines.length > 0 ? "(the items on this bill will have to be added again)" : ""}
            </span>
          )}
          <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Tap an item to add it · prices {pricesIncludeTax ? `include ${taxName}` : `before ${taxName}`}
          </span>
          {customerDisplay && (
            <button
              type="button"
              className="ml-auto text-xs font-bold"
              style={{ color: "var(--color-brand)" }}
              onClick={() => window.open("/display", "sna-customer-display", "popup,width=900,height=640")}
            >
              Open customer screen
            </button>
          )}
        </div>
        {tableOrdersWaiting > 0 && (
          <a
            href="/table-orders"
            className="mb-3 flex items-center justify-between rounded-2xl px-4 py-3 text-sm font-bold"
            style={{ background: "var(--color-accent)", color: "var(--color-accent-ink)" }}
          >
            <span>
              {tableOrdersWaiting} table order{tableOrdersWaiting === 1 ? "" : "s"} waiting from the QR menu
            </span>
            <span>Review →</span>
          </a>
        )}
        <input className="field mb-3" placeholder="Search the menu…" value={search} onChange={(e) => setSearch(e.target.value)} autoComplete="off" />
        {(tabs.length > 1 || Object.keys(categoryParents).length > 0) && (
          <div className="mb-4 flex gap-2 overflow-x-auto pb-1" role="group" aria-label="Menu categories">
            {[{ id: null as string | null, name: "All" }, ...tabs].map((c) => {
              // While a search is typed it looks everywhere, so no tab is shown as chosen.
              const on = !searching && activeTab === c.id;
              return (
                <button
                  key={c.id ?? "all"}
                  type="button"
                  aria-pressed={on}
                  onClick={() => {
                    setTab(c.id);
                    setSubTab(null);
                    setSearch("");
                  }}
                  className="min-h-[44px] shrink-0 whitespace-nowrap rounded-full border px-4 text-sm font-semibold"
                  style={{
                    borderColor: on ? "var(--color-brand)" : "var(--color-line)",
                    background: on ? "var(--color-brand)" : "var(--color-surface)",
                    color: on ? "#fff" : "var(--color-ink-2)",
                  }}
                >
                  {c.name}
                </button>
              );
            })}
          </div>
        )}
        {!searching && subTabs.length > 0 && (
          <div className="-mt-2 mb-4 flex gap-2 overflow-x-auto pb-1" role="group" aria-label="Sub-categories">
            {[{ id: null as string | null, name: `All ${tabs.find((t) => t.id === activeTab)?.name ?? ""}`.trim() }, ...subTabs].map((c) => {
              const on = activeSub === c.id;
              return (
                <button
                  key={c.id ?? "all-sub"}
                  type="button"
                  aria-pressed={on}
                  onClick={() => setSubTab(c.id)}
                  className="min-h-[44px] shrink-0 whitespace-nowrap rounded-xl border px-3.5 text-sm font-semibold"
                  style={{
                    borderColor: on ? "var(--color-brand)" : "var(--color-line)",
                    background: on ? "var(--color-brand-soft)" : "var(--color-surface)",
                    color: on ? "var(--color-brand-strong, var(--color-brand))" : "var(--color-ink-2)",
                  }}
                >
                  {c.name}
                </button>
              );
            })}
          </div>
        )}
        {categories.length === 0 && (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            No items match “{search}”.
          </p>
        )}
        <div className="space-y-5">
          {categories.map((cat) => (
            <section key={cat.id}>
              <h2 className="mb-2 text-xs font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
                {cat.name}
              </h2>
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
                {cat.items.map((item) => {
                  const inCart = qtyInCart(item.id);
                  return (
                    <button
                      key={item.id}
                      onClick={() => tapItem(item)}
                      className="tap card relative flex flex-col items-start justify-between gap-1 p-3 text-left transition active:scale-[0.98]"
                      style={{ borderColor: inCart ? "var(--color-brand)" : "var(--color-line)" }}
                    >
                      <span className="flex items-start gap-1.5 text-sm font-semibold leading-tight">
                        {item.is_veg != null && (
                          <span
                            className="mt-1 inline-block h-2.5 w-2.5 shrink-0 rounded-[3px]"
                            style={{ background: item.is_veg ? "var(--color-ok)" : "var(--color-bad)" }}
                          />
                        )}
                        <DishName name={item.name} local={item.name_local} />
                      </span>
                      <span className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                        {m(item.price)}
                        {item.groups.length > 0 && (
                          <span className="ml-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                            · options
                          </span>
                        )}
                      </span>
                      {inCart > 0 && (
                        <span
                          className="absolute right-2 top-2 grid h-5 min-w-5 place-items-center rounded-full px-1 text-[11px] font-bold text-white"
                          style={{ background: "var(--color-brand)" }}
                        >
                          {inCart}
                        </span>
                      )}
                    </button>
                  );
                })}
              </div>
            </section>
          ))}
        </div>
      </div>

      {lines.length > 0 && (
        <button
          type="button"
          className="fixed inset-x-3 bottom-3 z-40 flex items-center justify-between rounded-2xl px-4 py-3 text-sm font-bold shadow-lg lg:hidden"
          style={{ background: "var(--color-brand)", color: "#fff" }}
          onClick={() => document.getElementById("cart")?.scrollIntoView({ behavior: "smooth" })}
        >
          <span>
            View order · {lines.reduce((s, l) => s + l.qty, 0)} item{lines.reduce((s, l) => s + l.qty, 0) === 1 ? "" : "s"}
          </span>
          <span>{quote ? m(due) : m(addSubtotal)}</span>
        </button>
      )}

      <div id="cart" className="scroll-mt-4 pb-20 lg:sticky lg:top-4 lg:self-start lg:pb-0">
        <div className="card flex max-h-[calc(100vh-2rem)] flex-col">
          <div className="flex items-center justify-between border-b px-4 py-3" style={{ borderColor: "var(--color-line)" }}>
            <div className="text-sm font-bold">{addTo ? "Items to add" : "Current bill"}</div>
            {addTo ? (
              <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                {addTo.table ? `Table ${addTo.table} · ` : ""}bill {addTo.billNumber}
              </span>
            ) : (
              <div className="flex overflow-hidden rounded-lg border" style={{ borderColor: "var(--color-line)" }}>
                {(["dine_in", "takeaway", "delivery"] as const).map((t) => (
                  <button
                    key={t}
                    onClick={() => chooseOrderType(t)}
                    aria-pressed={orderType === t}
                    className="px-2.5 py-1.5 text-[11px] font-semibold"
                    style={{ background: orderType === t ? "var(--color-brand)" : "transparent", color: orderType === t ? "#fff" : "var(--color-ink-2)" }}
                  >
                    <Dual text={orderTypeLabel[t]} />
                  </button>
                ))}
              </div>
            )}
          </div>

          {!addTo && orderType === "dine_in" && tables.length > 0 && (
            <div className="border-b px-4 py-2" style={{ borderColor: "var(--color-line)" }}>
              <div className="mb-1.5 text-[11px] font-semibold" style={{ color: "var(--color-ink-3)" }}>
                Table
              </div>
              <div className="flex flex-wrap gap-1.5">
                <Chip label="None" active={tableId === null} onClick={() => chooseTable(null)} />
                {tables.map((t) => (
                  <Chip key={t.id} label={`T${t.number}`} busy={t.busy} active={tableId === t.id} onClick={() => chooseTable(t.id)} />
                ))}
              </div>
              {chosenTable && chosenTable.openBills.length > 0 && (
                <div className="mt-2 space-y-1.5 rounded-md px-2.5 py-2 text-xs" style={{ background: "var(--color-warn-soft)" }}>
                  {chosenTable.openBills.length > 1 && (
                    <div>
                      Table {chosenTable.number} has {chosenTable.openBills.length} open bills:
                    </div>
                  )}
                  {chosenTable.openBills.map((b) => (
                    <div key={b.id} className="flex items-center justify-between gap-2">
                      <span>{chosenTable.openBills.length > 1 ? b.billNumber : `Table ${chosenTable.number} has an open bill: ${b.billNumber}`}</span>
                      {saved ? null : offline ? (
                        <span className="shrink-0 text-right" style={{ color: "var(--color-ink-3)" }}>
                          Adding to it needs the internet
                        </span>
                      ) : (
                        <button
                          className="shrink-0 font-semibold underline"
                          style={{ color: "var(--color-brand-strong)" }}
                          onClick={() => openAddTo(b.id)}
                        >
                          Add to this bill
                        </button>
                      )}
                    </div>
                  ))}
                  {!offline && (
                    <label className="flex items-center gap-2 border-t pt-1.5 font-semibold" style={{ borderColor: "var(--color-line)" }}>
                      <input type="checkbox" className="h-5 w-5 shrink-0" checked={separateBill} onChange={(e) => setSeparateBill(e.target.checked)} />
                      Start a separate bill for this table
                    </label>
                  )}
                </div>
              )}
            </div>
          )}

          {!addTo && orderType !== "dine_in" && (
            <div className="border-b px-4 py-2" style={{ borderColor: "var(--color-line)" }}>
              <div className="mb-1.5 text-[11px] font-semibold" style={{ color: "var(--color-ink-3)" }}>
                Guest details (optional)
              </div>
              <div className="grid grid-cols-2 gap-1.5">
                <input
                  className="field text-sm"
                  style={GUEST_FIELD}
                  placeholder="Guest name"
                  aria-label="Guest name (optional)"
                  value={guestName}
                  maxLength={80}
                  autoComplete="off"
                  onChange={(e) => setGuestName(e.target.value)}
                />
                <input
                  className="field text-sm"
                  style={GUEST_FIELD}
                  type="tel"
                  inputMode="tel"
                  placeholder="Phone"
                  aria-label="Guest phone (optional)"
                  value={guestPhone}
                  maxLength={20}
                  autoComplete="off"
                  onChange={(e) => setGuestPhone(e.target.value)}
                />
              </div>
              {orderType === "delivery" && (
                <input
                  className="field mt-1.5 text-sm"
                  style={GUEST_FIELD}
                  placeholder="Delivery address"
                  aria-label="Delivery address (optional)"
                  value={guestAddress}
                  maxLength={300}
                  autoComplete="off"
                  onChange={(e) => setGuestAddress(e.target.value)}
                />
              )}
            </div>
          )}

          <div className="flex-1 overflow-y-auto px-4 py-2">
            {lines.length === 0 ? (
              <p className="py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                No items yet.
              </p>
            ) : (
              <>
              <ul>
                {lines.map((l) => (
                  <li key={l.key} className="border-b py-2 last:border-0" style={{ borderColor: "var(--color-line)" }}>
                  <div className="flex items-center gap-2">
                    <div className="min-w-0 flex-1">
                      <div className="truncate text-sm font-medium">{l.item.name}</div>
                      {l.options.length > 0 && (
                        <div className="truncate text-[11px]" style={{ color: "var(--color-ink-2)" }}>
                          {l.options.map((o) => o.name).join(", ")}
                        </div>
                      )}
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {m(unitPrice(l))}
                      </div>
                    </div>
                    <div className="flex items-center gap-1.5">
                      <button onClick={() => step(l.key, -1)} className="grid h-8 w-8 place-items-center rounded-md border text-base" style={{ borderColor: "var(--color-line)" }} aria-label={`One less ${l.item.name}`}>
                        −
                      </button>
                      <span className="w-5 text-center text-sm font-semibold">{l.qty}</span>
                      <button onClick={() => step(l.key, 1)} className="grid h-8 w-8 place-items-center rounded-md border text-base" style={{ borderColor: "var(--color-line)" }} aria-label={`One more ${l.item.name}`}>
                        +
                      </button>
                    </div>
                    <div className="w-20 text-right text-sm font-semibold">{m(Math.round(unitPrice(l) * l.qty * 100) / 100)}</div>
                  </div>
                  {noteOpen === l.key ? (
                    <div className="mt-2 space-y-1.5">
                      <input
                        className="field h-9 text-sm"
                        placeholder="Note for the kitchen, e.g. no onion"
                        value={l.note}
                        maxLength={200}
                        autoFocus
                        onChange={(e) => setNote(l.key, e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === "Enter") setNoteOpen(null);
                        }}
                        aria-label={`Kitchen note for ${l.item.name}`}
                      />
                      <div className="flex flex-wrap gap-1">
                        {QUICK_NOTES.map((q) => (
                          <button
                            key={q}
                            type="button"
                            className="rounded-md border px-2 py-1 text-[11px] font-semibold"
                            style={{ borderColor: "var(--color-line)" }}
                            onClick={() => setNote(l.key, l.note.trim() ? (l.note.includes(q) ? l.note : `${l.note.trim()}, ${q}`) : q)}
                          >
                            {q}
                          </button>
                        ))}
                        <button type="button" className="ml-auto rounded-md px-2 py-1 text-[11px] font-bold" style={{ color: "var(--color-brand-strong)" }} onClick={() => setNoteOpen(null)}>
                          Done
                        </button>
                      </div>
                    </div>
                  ) : (
                    <div className="mt-1 flex items-center gap-3">
                      <button
                        type="button"
                        className="text-left text-[11px] font-semibold"
                        style={{ color: l.note ? "var(--color-warn)" : "var(--color-ink-3)" }}
                        onClick={() => setNoteOpen(l.key)}
                      >
                        {l.note ? `Note: ${l.note}` : <Dual text="+ Kitchen note" />}
                      </button>
                      {!offline && allowHold && (
                        <button
                          type="button"
                          className="rounded-md px-1.5 text-[11px] font-semibold"
                          aria-pressed={!!l.hold}
                          style={l.hold ? { background: "var(--color-warn-soft)", color: "var(--color-warn)" } : { color: "var(--color-ink-3)" }}
                          onClick={() => toggleHold(l.key)}
                          title="Hold for the next course; send it to the kitchen from the bill later"
                        >
                          {l.hold ? "Held — next course" : <Dual text="Hold" />}
                        </button>
                      )}
                    </div>
                  )}
                  </li>
                ))}
              </ul>
              {packRule && (
                <label className="tap flex items-center gap-2 border-t text-sm" style={{ borderColor: "var(--color-line)" }}>
                  <span className="min-w-0 flex-1">
                    <span className="font-medium">{addTo ? "Add packing charge" : "Packing charge"}</span>
                    {packRule.per === "item" && (
                      <span className="ml-1.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {m(packRule.price)} × {packingQty}
                      </span>
                    )}
                    {addTo && (
                      <span className="block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                        This bill may already have one.
                      </span>
                    )}
                  </span>
                  <span className={packingTicked ? "font-semibold" : undefined} style={packingTicked ? undefined : { color: "var(--color-ink-3)" }}>
                    {m(packingAmount)}
                  </span>
                  <input
                    type="checkbox"
                    className="h-5 w-5 shrink-0"
                    checked={packingTicked}
                    onChange={(e) => setPackingChoice(e.target.checked)}
                    aria-label="Add the packing charge to this bill"
                  />
                </label>
              )}
              </>
            )}
          </div>

          {addTo ? (
            <div className="border-t px-4 py-3" style={{ borderColor: "var(--color-line)" }}>
              <div className="flex justify-between text-sm">
                <span style={{ color: "var(--color-ink-3)" }}>New items {pricesIncludeTax ? "" : `(before ${taxName})`}</span>
                <span className="font-semibold">{m(addSubtotal)}</span>
              </div>
              <p className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                The bill&rsquo;s tax, service charge and total are worked out again when you add. A new kitchen ticket is sent for these items only.
              </p>
              {offline && !saved && (
                <p className="mt-3 rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                  No connection. Adding to an open bill needs it; your items stay here and can be added as soon as it is back.
                </p>
              )}
              {error && !saved && <ErrorBox text={error} />}
              {saved && <SavedBox text="Added and sent to the kitchen. Printing the KOT…" slow={savedSlow} onOpen={() => router.push(saved)} />}
              <div className="mt-3 flex gap-2">
                <button onClick={() => router.push(`/bills/${addTo.id}`)} disabled={pending} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                  Back to bill
                </button>
                <button onClick={submitAdd} disabled={pending || lines.length === 0 || offline || !!saved} className="btn btn-primary flex-1">
                  {pending ? "Adding…" : `KOT · add ${lines.reduce((s, l) => s + l.qty, 0) || ""} to bill`}
                </button>
              </div>
            </div>
          ) : (
            <div className="border-t px-4 py-3" style={{ borderColor: "var(--color-line)" }}>
              {lines.length > 0 && (
                <div className="mb-3 space-y-2">
                  {quote?.service_charge_available && (
                    <label className="flex items-center justify-between text-sm">
                      <span>
                        {quote.service_charge_label} {Number(quote.service_charge_percent)}%
                      </span>
                      <input
                        type="checkbox"
                        className="h-5 w-5"
                        checked={quote.service_charge_on}
                        onChange={(e) => setScChoice(e.target.checked)}
                        aria-label="Add service charge to this bill"
                      />
                    </label>
                  )}
                  {(canDiscount || canPay) && !senior && (
                    <div className="flex items-center gap-2">
                      <label className="text-xs font-medium" style={{ color: "var(--color-ink-2)" }} htmlFor="discount">
                        Discount
                      </label>
                      <input id="discount" className="field h-9 flex-1 text-sm" inputMode="decimal" placeholder="0" value={discount} onChange={(e) => setDiscount(e.target.value)} />
                    </div>
                  )}
                  {discountAmt > 0 && !senior && (
                    <input className="field h-9 text-sm" placeholder="Discount reason (optional)" value={discountReason} onChange={(e) => setDiscountReason(e.target.value)} />
                  )}
                  {showSenior && (
                    <SeniorBox
                      senior={senior}
                      open={seniorOpen}
                      setOpen={setSeniorOpen}
                      onApply={(s) => {
                        setDiscount("");
                        setSenior(s);
                        setSeniorOpen(false);
                      }}
                      onRemove={() => setSenior(null)}
                    />
                  )}
                </div>
              )}

              <dl className="space-y-1 text-sm" aria-live="polite">
                <Row label="Subtotal" value={quote ? m(quote.subtotal) : lines.length ? "…" : m(0)} />
                {quote && quote.discount > 0 && <Row label="Discount" value={`−${m(quote.discount)}`} color="var(--color-ok)" />}
                {quote && quote.tax_exempt_amount > 0 && <Row label="VAT exemption" value={`−${m(quote.tax_exempt_amount)}`} color="var(--color-ok)" />}
                {quote && quote.senior_discount > 0 && <Row label="Senior/PWD 20%" value={`−${m(quote.senior_discount)}`} color="var(--color-ok)" />}
                {quote && quote.service_charge > 0 && <Row label={quote.service_charge_label} value={m(quote.service_charge)} />}
                {quote && addedTax > 0 && <Row label={taxName} value={m(addedTax)} />}
                {quote && Math.abs(quote.rounding) >= 0.005 && <Row label="Rounding" value={`${quote.rounding > 0 ? "+" : "−"}${m(Math.abs(quote.rounding))}`} />}
                {quote && Math.abs(cashRound) >= 0.005 && <Row label="Cash rounding" value={`${cashRound > 0 ? "+" : "−"}${m(Math.abs(cashRound))}`} />}
                <div className="flex justify-between border-t pt-1.5 text-base font-bold" style={{ borderColor: "var(--color-line)" }}>
                  <dt>Total</dt>
                  <dd>{quote ? m(due) : lines.length ? "…" : m(0)}</dd>
                </div>
                {quote && quote.tax_included > 0 && (
                  <div className="text-right text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    includes {taxName} {m(quote.tax_included)}
                  </div>
                )}
              </dl>

              <div className="mt-3">
                <div className="mb-1.5 text-xs font-medium" style={{ color: "var(--color-ink-2)" }}>
                  Payment
                </div>
                <div className="grid grid-cols-3 gap-1.5">
                  {paymentMethods.map((p) => (
                    <button
                      key={p.id}
                      onClick={() => setMethodId(p.id)}
                      className="rounded-lg border px-2 py-2 text-xs font-semibold"
                      style={{
                        borderColor: methodId === p.id ? "var(--color-brand)" : "var(--color-line)",
                        background: methodId === p.id ? "var(--color-brand-soft)" : "transparent",
                        color: methodId === p.id ? "var(--color-brand-strong)" : "var(--color-ink-2)",
                      }}
                    >
                      {p.name}
                    </button>
                  ))}
                </div>
                {(() => {
                  const upi = paymentMethods.find((p) => p.id === methodId && p.kind === "upi" && p.upi_id);
                  return upi?.upi_id && upiPayee && quote && due > 0 ? (
                    <div className="mt-2 rounded-lg border p-2" style={{ borderColor: "var(--color-line)", background: "#fff" }}>
                      <UpiQr upiId={upi.upi_id} payee={upiPayee} amount={due} note="Bill" size={132} />
                    </div>
                  ) : null;
                })()}
                {askRef && !isCash && (
                  <input
                    className="field mt-2 h-9 text-sm"
                    placeholder="Reference, e.g. UPI txn ID or card last 4 (optional)"
                    value={reference}
                    maxLength={60}
                    onChange={(e) => setReference(e.target.value)}
                  />
                )}
                {isCash && (
                  <div className="mt-2 flex items-center gap-2">
                    <input className="field h-9 flex-1 text-sm" inputMode="decimal" placeholder="Cash received" value={tendered} onChange={(e) => setTendered(e.target.value)} />
                    <div className="w-28 text-right text-sm">
                      <span style={{ color: "var(--color-ink-3)" }}>Change </span>
                      <span className="font-semibold">{m(change)}</span>
                    </div>
                  </div>
                )}
              </div>

              {maybeSaved && !saved && (
                <ErrorBox text="The connection dropped while saving, so this bill may already be saved. Look in Bills before you save it again. To bill offline now, press the button again." />
              )}
              {error && !saved && <ErrorBox text={error} />}
              {saved && <SavedBox text={saved.startsWith("/pos/kot/") ? "Sent to the kitchen. Printing the KOT…" : "Saved. Opening the bill…"} slow={savedSlow} onOpen={() => router.push(saved)} onNext={startNextBill} />}
              {needSeparate && lines.length > 0 && (
                <p className="mt-3 rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                  Table {chosenTable?.number} already has an open bill. Add to it, or tick &ldquo;Start a separate bill for this table&rdquo; above.
                </p>
              )}

              <div className="mt-3 flex gap-2">
                <button onClick={clearAll} disabled={pending || lines.length === 0 || !!saved} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                  Clear
                </button>
                {canPay ? (
                  <>
                    <button
                      onClick={() => submit("unpaid")}
                      disabled={pending || quoting || !quote || needSeparate || !!saved}
                      className="btn border px-4 text-base font-bold"
                      style={{ borderColor: "var(--color-brand)", background: "var(--color-surface)", color: "var(--color-brand-strong, var(--color-brand))" }}
                      title="Send the order to the kitchen and print the KOT. The bill stays open: print it and take the payment later."
                    >
                      KOT
                    </button>
                    <button onClick={() => submit("pay")} disabled={pending || quoting || !quote || needSeparate || !!saved} className="btn btn-pay flex-1 text-base">
                      {pending ? "Saving…" : <Dual text="Charge" />}
                      {!pending && quote ? ` ${m(due)}` : ""}
                    </button>
                  </>
                ) : (
                  <button
                    onClick={() => submit("unpaid")}
                    disabled={pending || quoting || !quote || needSeparate || !!saved}
                    className="btn btn-primary flex-1 text-base"
                    title="Send the order to the kitchen and print the KOT. The cashier takes the payment later."
                  >
                    {pending ? "Saving…" : "KOT"}
                  </button>
                )}
              </div>
              {canPay ? (
                <button
                  onClick={() => submit("split")}
                  disabled={pending || quoting || !quote || needSeparate || !!saved}
                  className="mt-2 w-full text-center text-xs font-semibold"
                  style={{ color: "var(--color-brand-strong)" }}
                >
                  Split payment (part cash, part card/UPI, or share between people)
                </button>
              ) : (
                <p className="mt-2 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>
                  The cashier takes the payment.
                </p>
              )}
            </div>
          )}
        </div>
      </div>

      {offlineBill && snap && (
        <OfflineReceipt
          bill={offlineBill}
          snap={snap}
          onDone={() => {
            setOfflineBill(null);
            clearAll();
            setCart({});
          }}
        />
      )}

      {approval && (
        <ApprovalPrompt
          permission={approval.permission}
          onCancel={() => setApproval(null)}
          onApproved={() => {
            const r = approval.retry;
            setApproval(null);
            r();
          }}
        />
      )}

      {picking && (
        <OptionPicker
          item={picking}
          currency={currency}
          onCancel={() => setPicking(null)}
          onAdd={(opts) => {
            addLine(picking, opts);
            setPicking(null);
          }}
        />
      )}
    </div>
  );
}

function OptionPicker({
  item,
  currency,
  onCancel,
  onAdd,
}: {
  item: MenuItem;
  currency: string;
  onCancel: () => void;
  onAdd: (opts: ChosenOption[]) => void;
}) {
  const [chosen, setChosen] = useState<Record<string, string[]>>(() => {
    // Pre-select the first choice of a required pick-one group, so the common case is one tap.
    const init: Record<string, string[]> = {};
    for (const g of item.groups) if (g.min >= 1 && g.max === 1 && g.options[0]) init[g.id] = [g.options[0].id];
    return init;
  });
  const m = (n: number) => money(n, currency);

  function toggle(g: OptionGroup, optId: string) {
    setChosen((c) => {
      const cur = c[g.id] ?? [];
      if (g.max === 1) return { ...c, [g.id]: cur[0] === optId && g.min === 0 ? [] : [optId] };
      if (cur.includes(optId)) return { ...c, [g.id]: cur.filter((x) => x !== optId) };
      if (cur.length >= g.max) return c;
      return { ...c, [g.id]: [...cur, optId] };
    });
  }

  const missing = item.groups.find((g) => (chosen[g.id]?.length ?? 0) < g.min);
  const opts: ChosenOption[] = item.groups.flatMap((g) => g.options.filter((o) => chosen[g.id]?.includes(o.id)));
  const total = Math.round((item.price + opts.reduce((s, o) => s + o.price, 0)) * 100) / 100;

  return (
    <div
      className="fixed inset-0 z-50 grid place-items-center p-4"
      style={{ background: "rgba(10,8,20,.55)" }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onCancel();
      }}
    >
      <div className="card w-full max-w-md p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label={`Options for ${item.name}`}>
        <h3 className="text-lg font-bold">{item.name}</h3>
        <div className="mt-4 max-h-[60vh] space-y-4 overflow-y-auto">
          {item.groups.map((g) => (
            <fieldset key={g.id}>
              <legend className="mb-1.5 text-sm font-semibold">
                {g.name}{" "}
                <span className="text-xs font-normal" style={{ color: "var(--color-ink-3)" }}>
                  {g.min >= 1 ? (g.max === 1 ? "choose 1" : `choose ${g.min}–${g.max}`) : g.max === 1 ? "optional" : `optional, up to ${g.max}`}
                </span>
              </legend>
              <div className="grid grid-cols-2 gap-1.5">
                {g.options.map((o) => {
                  const on = chosen[g.id]?.includes(o.id) ?? false;
                  return (
                    <button
                      key={o.id}
                      onClick={() => toggle(g, o.id)}
                      aria-pressed={on}
                      className="flex items-center justify-between gap-2 rounded-lg border px-3 py-2.5 text-left text-sm"
                      style={{
                        borderColor: on ? "var(--color-brand)" : "var(--color-line)",
                        background: on ? "var(--color-brand-soft)" : "transparent",
                      }}
                    >
                      <span className="font-medium">{o.name}</span>
                      {o.price !== 0 && (
                        <span className="text-xs" style={{ color: "var(--color-ink-2)" }}>
                          {o.price > 0 ? "+" : "−"}
                          {m(Math.abs(o.price))}
                        </span>
                      )}
                    </button>
                  );
                })}
              </div>
            </fieldset>
          ))}
        </div>
        {missing && (
          <p className="mt-3 text-xs" style={{ color: "var(--color-warn)" }}>
            Choose {missing.name.toLowerCase()} to continue.
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={onCancel}>
            Cancel
          </button>
          <button className="btn btn-primary flex-1" disabled={!!missing} onClick={() => onAdd(opts)}>
            Add · {m(total)}
          </button>
        </div>
      </div>
    </div>
  );
}

/** Shown from the moment a bill is saved until the screen has moved on to it. */
function SavedBox({ text, slow, onOpen, onNext }: { text: string; slow: boolean; onOpen: () => void; onNext?: () => void }) {
  return (
    <div className="mt-3 rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}>
      <b>{text}</b>
      {slow && (
        <div className="mt-1.5">
          <div style={{ color: "var(--color-ink-2)" }}>
            This is taking longer than usual. The bill is saved. If you start the next one now, find this one in Bills to print it.
          </div>
          <div className="mt-1.5 flex flex-wrap gap-2">
            <button className="min-h-11 rounded-lg border px-3 font-bold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)", color: "var(--color-ink)" }} onClick={onOpen}>
              Open it
            </button>
            {onNext && (
              <button className="min-h-11 rounded-lg border px-3 font-bold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)", color: "var(--color-ink)" }} onClick={onNext}>
                Start the next bill
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function ErrorBox({ text }: { text: string }) {
  return (
    <p className="mt-3 rounded-lg px-3 py-2 text-xs" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
      {text}
    </p>
  );
}

function SeniorBox({
  senior,
  open,
  setOpen,
  onApply,
  onRemove,
}: {
  senior: Senior | null;
  open: boolean;
  setOpen: (v: boolean) => void;
  onApply: (s: Senior) => void;
  onRemove: () => void;
}) {
  const [kind, setKind] = useState<"senior" | "pwd">("senior");
  const [count, setCount] = useState("1");
  const [diners, setDiners] = useState("1");
  const [name, setName] = useState("");
  const [idNo, setIdNo] = useState("");

  if (senior) {
    return (
      <div className="flex items-center justify-between rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-ok-soft)" }}>
        <span>
          {senior.kind === "pwd" ? "PWD" : "Senior"} {senior.count} of {senior.diners}: {senior.name} ({senior.id_no})
        </span>
        <button className="font-semibold" style={{ color: "var(--color-bad)" }} onClick={onRemove}>
          Remove
        </button>
      </div>
    );
  }
  if (!open) {
    return (
      <button className="w-full rounded-lg border px-3 py-2 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setOpen(true)}>
        Senior citizen / PWD discount
      </button>
    );
  }
  return (
    <div className="space-y-2 rounded-lg border p-3" style={{ borderColor: "var(--color-line)" }}>
      <div className="flex gap-1.5">
        {(["senior", "pwd"] as const).map((k) => (
          <button
            key={k}
            onClick={() => setKind(k)}
            className="flex-1 rounded-md border px-2 py-1.5 text-xs font-semibold"
            style={{ borderColor: kind === k ? "var(--color-brand)" : "var(--color-line)", background: kind === k ? "var(--color-brand-soft)" : "transparent" }}
          >
            {k === "senior" ? "Senior citizen" : "PWD"}
          </button>
        ))}
      </div>
      <div className="grid grid-cols-2 gap-2">
        <label className="text-[11px]">
          How many
          <input className="field h-9 text-sm" inputMode="numeric" value={count} onChange={(e) => setCount(e.target.value)} />
        </label>
        <label className="text-[11px]">
          People at the table
          <input className="field h-9 text-sm" inputMode="numeric" value={diners} onChange={(e) => setDiners(e.target.value)} />
        </label>
      </div>
      <input className="field h-9 text-sm" placeholder="Name on ID" value={name} onChange={(e) => setName(e.target.value)} />
      <input className="field h-9 text-sm" placeholder={kind === "pwd" ? "PWD ID number" : "OSCA ID number"} value={idNo} onChange={(e) => setIdNo(e.target.value)} />
      <div className="flex gap-2">
        <button className="btn h-9 flex-1 border text-xs" style={{ borderColor: "var(--color-line)" }} onClick={() => setOpen(false)}>
          Cancel
        </button>
        <button
          className="btn btn-primary h-9 flex-1 text-xs"
          disabled={!name.trim() || !idNo.trim() || !(Number(count) >= 1) || !(Number(diners) >= Number(count))}
          onClick={() => onApply({ kind, count: Number(count), diners: Number(diners), name: name.trim(), id_no: idNo.trim() })}
        >
          Apply
        </button>
      </div>
    </div>
  );
}

function Row({ label, value, color }: { label: string; value: string; color?: string }) {
  return (
    <div className="flex justify-between" style={color ? { color } : undefined}>
      <dt style={color ? undefined : { color: "var(--color-ink-3)" }}>{label}</dt>
      <dd>{value}</dd>
    </div>
  );
}

function Chip({ label, active, busy, onClick }: { label: string; active: boolean; busy?: boolean; onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      className="rounded-md border px-2.5 py-1 text-xs font-semibold"
      aria-label={busy ? `${label}, has an unpaid bill` : label}
      style={{
        borderColor: active ? "var(--color-brand)" : busy ? "var(--color-warn)" : "var(--color-line)",
        background: active ? "var(--color-brand)" : busy ? "var(--color-warn-soft)" : "transparent",
        color: active ? "#fff" : busy ? "var(--color-warn)" : "var(--color-ink-2)",
      }}
    >
      {label}
    </button>
  );
}
