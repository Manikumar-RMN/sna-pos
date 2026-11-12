"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { createPortal } from "react-dom";
import { useRouter } from "next/navigation";
import { money, orderTypeLabel, roundCash } from "@/lib/format";
import { parseDiscountInput } from "@/lib/discount";
import { UpiQr } from "../upi-qr";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { addToBill, getOfflineSnapshot, placeOrder, quoteOrder, stockWarnings, type CartItem, type PlaceOrderInput, type Quote, type Senior } from "./actions";
import { makeComplimentary } from "../bills/actions";
import { NcChargeSelect } from "../bills/nc-charge-select";
import { customerFavourites, findCustomer, type GuestFavourites, type RegularGuest } from "../bills/actions";
import { regularChipText } from "../bills/loyalty-math";
import { loadLastRound, loadOneLine } from "./repeat-round";
import { createQuickDish } from "../menu/actions";
import { mapRoundToMenu } from "@/lib/repeat-round";
import { coversError, deskCarryUsable, needsInternetText, openPriceError, openPriceValue, parseCovers } from "@/lib/order-desk";
import { cashDue, deviceKey, offlineQuote, readQueue, readSnapshot, saveSnapshot, takeNumber, writeQueue, type OfflineBill, type Snapshot } from "@/lib/offline";
import { OfflineReceipt } from "./offline-receipt";
import { stripText, warnedProducts, type StockWarning } from "./stock-warning";
import { DishName, Dual } from "../lang";

export type OptionGroup = {
  id: string;
  name: string;
  min: number;
  max: number;
  options: { id: string; name: string; price: number }[];
};
export type MenuItem = {
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
  /** Set on a size (Small, Large, Half…): the dish it belongs to. Sizes are not shown as cards of their own. */
  variantOf?: string | null;
  /** Set on a dish sold in sizes: the sizes on sale, cheapest first. Tapping the dish asks which one. */
  variants?: { id: string; name: string; price: number }[];
  /** A combo / meal deal (its choices are other dishes). */
  isCombo?: boolean;
  /** Set while an offer (happy hour) lowers the price: the normal price, shown struck through. */
  listPrice?: number;
  /** Sold by weight: the price is per kg and the quantity is the weight in kg. */
  byWeight?: boolean;
  /** Item code for the barcode scanner and weighing-scale labels. */
  barcode?: string;
  /** Counted in batches: how many are left today at this outlet. */
  left?: number;
  /** Bars: liquor goes only on separate liquor bills (its own numbers and VAT). */
  liquor?: boolean;
  /** Open price: the price is typed at the till when the dish is tapped (needs the order.open_price right and the internet). */
  is_open_price?: boolean;
  /** Marked "Do not allow discounts": a bill discount never takes a share of this dish (the database enforces it too). */
  no_discount?: boolean;
};

/**
 * A weighing-scale label: 13 digits starting with 2 — prefix (2 digits), item code (5), weight in grams (5), check digit.
 * Returns the item code and the weight in kg, or null when the code is not such a label.
 */
export function parseScaleLabel(code: string): { itemCode: string; kg: number } | null {
  if (!/^2\d{12}$/.test(code)) return null;
  const grams = Number(code.slice(7, 12));
  if (!grams) return null;
  return { itemCode: code.slice(2, 7), kg: Math.round(grams) / 1000 };
}

/** "0.350 kg" for weighed items, "2" for pieces. */
export function qtyText(qty: number, byWeight?: boolean) {
  return byWeight ? `${qty.toFixed(3)} kg` : String(qty);
}
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
export type ChosenOption = { id: string; name: string; price: number };
/** openPrice: the price typed for an open-priced dish. Lines with different typed prices are different lines. */
type CartLine = { key: string; item: MenuItem; qty: number; options: ChosenOption[]; note: string; hold?: boolean; openPrice?: number };

/** One-tap kitchen notes; staff can also type their own. */
const QUICK_NOTES = ["No onion", "No garlic", "Less spicy", "Extra spicy", "Less oil", "Parcel"];
/** The optional guest boxes are smaller than the usual input so they do not push the bill down. */
const GUEST_FIELD = { minHeight: 40, padding: "0 12px" } as const;
/** where / token: only the single order screen uses them, to print the kitchen ticket without leaving the screen. */
export type AddTo = { id: string; billNumber: string; table: string | null; where?: string; token?: number | null };

/** The single order screen asks to print the kitchen ticket of a bill that was just sent. */
export type KotDone = { orderId: string; billNumber: string; where: string; token: number | null; kind: "new" | "add" };

function lineKey(productId: string, options: ChosenOption[], openPrice?: number) {
  return productId + "|" + options.map((o) => o.id).sort().join(",") + (openPrice != null ? `|p${openPrice.toFixed(2)}` : "");
}
function unitPrice(l: { item: MenuItem; options: ChosenOption[]; openPrice?: number }) {
  return Math.round(((l.openPrice ?? l.item.price) + l.options.reduce((s, o) => s + o.price, 0)) * 100) / 100;
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
    const item = menu.find((it) => it.id === l.p && it.id !== packingId && !it.is_open_price);
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
/**
 * Table switch on the single order screen: the unsent cart follows staff to the newly chosen table / bill / counter. Nothing is
 * saved on the server before Send KOT, so this copy in sessionStorage is the only one: the new screen takes it once (it is removed
 * when read), only for the destination it was made for, and for at most two minutes. Besides what AddTo carries it keeps the typed
 * open price and (not to a running bill) the discount boxes. Never a payment, guests or guest details.
 */
const DESK_CARRY_KEY = "sna.pos.deskcarry.v1";
type DeskCarriedLine = CarriedLine & { pr?: number };
function clearDeskCarry() {
  try {
    sessionStorage.removeItem(DESK_CARRY_KEY);
  } catch {
    // no storage: nothing was kept
  }
}
function takeDeskCarry(
  destKey: string,
  menu: MenuItem[],
  packingId: string | null,
  allowHold: boolean,
  canOpenPrice: boolean,
  destTableId: string | null,
): { cart: Record<string, CartLine>; dropped: number; discount: string; reason: string } | null {
  let raw: string | null;
  try {
    raw = sessionStorage.getItem(DESK_CARRY_KEY);
    sessionStorage.removeItem(DESK_CARRY_KEY);
  } catch {
    return null;
  }
  if (!raw) return null;
  let saved: { to?: unknown; at?: unknown; lines?: unknown; d?: unknown; dr?: unknown } | null;
  try {
    saved = JSON.parse(raw);
  } catch {
    return null;
  }
  // A table that gained its single open bill since the strip was drawn opens as that bill (the server redirects): same table, so still ours.
  const redirected = !!saved && typeof saved.to === "string" && saved.to.startsWith("t:") && destKey.startsWith("b:") && destTableId !== null && saved.to === `t:${destTableId}`;
  if (!saved || !Array.isArray(saved.lines) || !deskCarryUsable(saved, redirected ? (saved.to as string) : destKey, Date.now())) return null;
  const cart: Record<string, CartLine> = {};
  let dropped = 0;
  saved.lines.forEach((x: unknown, i: number) => {
    const l = (x && typeof x === "object" ? x : {}) as { [K in keyof DeskCarriedLine]?: unknown };
    const item = menu.find((it) => it.id === l.p && it.id !== packingId);
    const ids = Array.isArray(l.o) ? [...new Set<unknown>(l.o)] : null;
    const qty = l.q;
    const pr = typeof l.pr === "number" && l.pr > 0 && l.pr < 100_000_000 ? Math.round(l.pr * 100) / 100 : undefined;
    const openOk = !item?.is_open_price || (canOpenPrice && pr !== undefined);
    const options: ChosenOption[] = item && ids ? item.groups.flatMap((g) => g.options.filter((o) => ids.includes(o.id))) : [];
    if (!item || !ids || !openOk || options.length !== ids.length || typeof qty !== "number" || !Number.isInteger(qty) || qty < 1) {
      dropped++;
      return;
    }
    const price = item.is_open_price ? pr : undefined;
    const base = lineKey(item.id, options, price);
    const key = cart[base] ? `${base}#c${i}` : base;
    const line: CartLine = { key, item, options, qty, note: typeof l.n === "string" ? l.n.slice(0, 200) : "" };
    if (price !== undefined) line.openPrice = price;
    if (allowHold && l.h === true) line.hold = true;
    cart[key] = line;
  });
  return {
    cart,
    dropped,
    discount: !destKey.startsWith("b:") && typeof saved.d === "string" ? saved.d.slice(0, 20) : "",
    reason: !destKey.startsWith("b:") && typeof saved.dr === "string" ? saved.dr.slice(0, 200) : "",
  };
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
  topSellerIds = [],
  discountPresets = [],
  paymentMethods,
  tables,
  addTo,
  packing = null,
  allowHold = false,
  customerDisplay = null,
  tableOrdersWaiting = 0,
  licenceLockAt = null,
  categoryParents = {},
  categoryBrands = {},
  orderTypes = [],
  startType,
  lockedTable = null,
  inline = false,
  onKotDone,
  askCovers = false,
  canOpenPrice = false,
  onCartCount,
  stockCheck = false,
  deskKey = null,
  deskTableId = null,
  stashRef = null,
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
  /** Product ids of the outlet's best sellers (last 30 days), best first: shown as one-tap buttons above the menu. */
  topSellerIds?: string[];
  /** Saved discounts valid today (Settings → Discounts): one tap fills the discount and its reason. */
  discountPresets?: { id: string; name: string; kind: "percent" | "amount"; value: number; orderTypes: string[] }[];
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
  /** Kinds of bill this outlet uses; empty means all three. */
  orderTypes?: OrderType[];
  /** The kind of bill the screen starts on. */
  startType?: string | null;
  /** Single order screen: the table was chosen on the table strip, so this is a dine-in bill for it (no table chips, no bill-type buttons). */
  lockedTable?: { id: string; number: string; separate?: boolean } | null;
  /** Single order screen: drawn inside that screen (narrower cart, no own "back" buttons, "Charge" opens the bill beside it). */
  inline?: boolean;
  /** Single order screen: called instead of moving to the KOT page once the order is saved; the screen prints the ticket in an overlay. */
  onKotDone?: (done: KotDone) => void;
  /** Single order screen: ask for the number of guests on a dine-in bill (at least 1; a screen rule only). */
  askCovers?: boolean;
  /** The person has the order.open_price right (the database checks it again). */
  canOpenPrice?: boolean;
  /** Single order screen: how many items wait in the cart, so the screen can ask before they are thrown away. */
  onCartCount?: (n: number) => void;
  /** Single order screen: the key of this selection (counter / t:id / b:id); the kept cart of a table switch is taken for it on start. */
  deskKey?: string | null;
  /** Single order screen, a bill selected: the table that bill is on (a table tapped just after it got its one bill opens as that bill). */
  deskTableId?: string | null;
  /** Single order screen: filled with a function that keeps the unsent cart for the next selection (see DESK_CARRY_KEY). */
  stashRef?: { current: ((destKey: string, toRunningBill: boolean) => "kept" | "empty" | "busy") | null } | null;
  /** The restaurant has the stock module: ask the database whether the order runs an ingredient short (a warning only, online only). */
  stockCheck?: boolean;
  categoryParents?: Record<string, { id: string; name: string }>;
  /** Cloud kitchen / food court: category id → brand. The billing screen can show one brand at a time. */
  categoryBrands?: Record<string, { id: string; name: string }>;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [cart, setCart] = useState<Record<string, CartLine>>({});
  const [search, setSearch] = useState("");
  /** The quick "Code" box: the item code typed from memory (the same code the barcode scanner uses). */
  const [code, setCode] = useState("");
  const [codeMsg, setCodeMsg] = useState<string | null>(null);
  /** Category tab; null = All. Not remembered between visits. */
  const [tab, setTab] = useState<string | null>(null);
  /** Sub-category tab inside the chosen main category; null = all of it. */
  const [subTab, setSubTab] = useState<string | null>(null);
  // The kinds of bill this outlet uses (Settings → Service charge); the screen starts on the outlet's choice.
  const kinds: OrderType[] = orderTypes.length ? orderTypes : ["dine_in", "takeaway", "delivery"];
  const [orderType, setOrderType] = useState<OrderType>(() =>
    lockedTable ? "dine_in" : startType && kinds.includes(startType as OrderType) ? (startType as OrderType) : kinds[0],
  );
  const [tableId, setTableId] = useState<string | null>(lockedTable?.id ?? null);
  /** The cashier chose to start a second bill on a table that already has an open one. */
  const [separateBill, setSeparateBill] = useState(!!lockedTable?.separate);
  // Single order screen: guests at the table (dine-in), asked before the order is sent.
  const [covers, setCovers] = useState("");
  const coversNum = parseCovers(covers);
  // Winsar flow: tapping a free table opens a cover keypad first (1-9, 0, 00, Back / Next).
  const [coverKeypad, setCoverKeypad] = useState(askCovers && inline && !!lockedTable);
  const [keypadText, setKeypadText] = useState("");
  // Winsar "NC KOT": the order is sent as a no-charge bill. The reason is asked here, as the database insists on one.
  const [ncKot, setNcKot] = useState(false);
  const [ncReason, setNcReason] = useState("");
  const [ncCharge, setNcCharge] = useState("");
  const [ncTargets, setNcTargets] = useState(0);
  // Winsar "Open +": a new dish made on the spot in the group being shown.
  const [quickOpen, setQuickOpen] = useState(false);
  /** Winsar "Open list": only the open-price dishes of the group being shown. */
  const [openOnly, setOpenOnly] = useState(false);
  /** Winsar: the line you tapped in the bill. The special instruction and the stepper work on it. */
  const [pickedLine, setPickedLine] = useState<string | null>(null);
  const [quickName, setQuickName] = useState("");
  const [quickPrice, setQuickPrice] = useState("");
  const [quickErr, setQuickErr] = useState<string | null>(null);
  const [quickBusy, setQuickBusy] = useState(false);
  // Open-priced dish: the price box, and the price chosen while its options are being picked.
  const [pricing, setPricing] = useState<MenuItem | null>(null);
  const [pickPrice, setPickPrice] = useState<number | null>(null);
  const [repeating, setRepeating] = useState(false);
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
  const presetsHere = discountPresets.filter((x) => x.orderTypes.length === 0 || x.orderTypes.includes(orderType));
  const [scChoice, setScChoice] = useState<boolean | null>(null);
  const [senior, setSenior] = useState<Senior | null>(null);
  const [seniorOpen, setSeniorOpen] = useState(false);
  const [picking, setPicking] = useState<MenuItem | null>(null);
  const [sizing, setSizing] = useState<MenuItem | null>(null);
  const [weighing, setWeighing] = useState<{ item: MenuItem; key?: string; kg?: number } | null>(null);
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
  // A returning guest typed in the phone box (takeaway / delivery): a hint with favourite dishes that can be added with one tap. Never blocks the order.
  const [regular, setRegular] = useState<RegularGuest | null>(null);
  const [favs, setFavs] = useState<GuestFavourites | null>(null);
  useEffect(() => {
    if (offline || orderType === "dine_in" || guestPhone.replace(/\D/g, "").length < 7) {
      setRegular(null);
      setFavs(null);
      return;
    }
    let live = true;
    const t = setTimeout(() => {
      findCustomer(guestPhone)
        .then(async (g) => {
          if (!live) return;
          setRegular(g);
          const f = g ? await customerFavourites(g.id) : null;
          if (live) setFavs(f);
        })
        .catch(() => {
          if (live) {
            setRegular(null);
            setFavs(null);
          }
        });
    }, 600);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [guestPhone, orderType, offline]);
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
  /** Which table (or the counter) this order goes to, on the single order screen. */
  // Winsar flow: a table order ends at KOT; the money is taken on the bill (Check → Settle). The counter keeps its one-tap Charge.
  const tableOrder = inline && !!lockedTable;
  /** A running bill on the single order screen (/pos?bill=): the new items use the same list-left, menu-right look and bottom bar as a new table order. */
  const billOrder = inline && !!addTo && !!deskKey;
  const winStyle = tableOrder || billOrder;
  /** On wide screens the new items are listed inside the bill's "Order so far" box (one list, like Winsar): the slot is a div in that box. */
  const [wide, setWide] = useState(false);
  const [slot, setSlot] = useState<HTMLElement | null>(null);
  const [totalSlot, setTotalSlot] = useState<HTMLElement | null>(null);
  useEffect(() => {
    if (!billOrder) return;
    const mq = window.matchMedia("(min-width: 1280px)");
    const on = () => setWide(mq.matches);
    on();
    mq.addEventListener("change", on);
    return () => mq.removeEventListener("change", on);
  }, [billOrder]);
  useEffect(() => {
    if (!billOrder) return;
    const find = () => {
      setSlot((prev) => {
        const el = document.getElementById("desk-new-rows");
        return prev === el ? prev : el;
      });
      setTotalSlot((prev) => {
        const el = document.getElementById("desk-new-total");
        return prev === el ? prev : el;
      });
    };
    find();
    const t = setInterval(find, 400);
    return () => clearInterval(t);
  }, [billOrder]);
  const merged = billOrder && wide && !!slot;
  const whereLabel = addTo ? (addTo.table ? `Table ${addTo.table}` : null) : lockedTable ? `Table ${lockedTable.number}` : deskKey ? "Counter" : null;
  // Bars: liquor and food may not share a bill.
  const mixedLiquor = lines.some((l) => l.item.liquor) && lines.some((l) => !l.item.liquor);
  const isCash = paymentMethods.find((p) => p.id === methodId)?.kind === "cash";
  const askRef = !!paymentMethods.find((p) => p.id === methodId)?.ask_reference;
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
  const packingQty = packRule?.per === "item" ? Math.max(1, Math.ceil(lines.reduce((s, l) => s + (l.item.byWeight ? 1 : l.qty), 0))) : 1;
  const packingAmount = packRule ? Math.round(packRule.price * packingQty * 100) / 100 : 0;
  // The discount box takes an amount or a percent ("10%"). A percent is worked out on the same base the bill
  // calculation uses (sum of price x qty, packing charge included), so it follows the cart when lines change and
  // works the same without internet. Only the amount is ever sent.
  // Dishes marked "Do not allow discounts" take no share, so a percent is worked out on the POOL (the rest), not the whole
  // subtotal. The packing charge is a dish like any other: it follows its own mark.
  const offlineNoDisc = (id: string) => !!snap?.menu.find((x) => x.id === id)?.no_discount;
  const noDisc = (l: CartLine) => !!l.item.no_discount || (offline && offlineNoDisc(l.item.id));
  const packingNoDisc = !!packRule && (!!menu.find((x) => x.id === packRule.productId)?.no_discount || (offline && offlineNoDisc(packRule.productId)));
  const packingIn = packingTicked && lines.length > 0 ? packingAmount : 0;
  const discountBase = Math.round((lines.reduce((s, l) => s + (noDisc(l) ? 0 : unitPrice(l) * l.qty), 0) + (packingNoDisc ? 0 : packingIn)) * 100) / 100;
  const wholeBase = Math.round((lines.reduce((s, l) => s + unitPrice(l) * l.qty, 0) + packingIn) * 100) / 100;
  /** Something is in the cart but none of it may be discounted: the box is off. */
  const nothingDiscountable = lines.length > 0 && discountBase === 0;
  const discountParsed = parseDiscountInput(discount, discountBase);
  const discountAmt = discountParsed.ok ? discountParsed.amount : 0;

  // Brands / stalls on this menu, in menu order; choosing one shows only its dishes.
  const brandTabs = useMemo(() => {
    const out: { id: string; name: string }[] = [];
    for (const x of menu) {
      const b = categoryBrands[x.category_id];
      if (b && !out.some((y) => y.id === b.id)) out.push(b);
    }
    return out;
  }, [menu, categoryBrands]);
  const [brand, setBrand] = useState<string | null>(null);
  const activeBrand = brand !== null && brandTabs.some((b) => b.id === brand) ? brand : null;
  const brandMenu = useMemo(
    () => (activeBrand === null ? menu : menu.filter((x) => categoryBrands[x.category_id]?.id === activeBrand)),
    [menu, activeBrand, categoryBrands],
  );

  // Category tabs, in menu order: main categories; a sub-category's dishes come under its main one.
  // The packing charge is not sold from the menu.
  const tabs = useMemo(() => {
    const out: { id: string; name: string }[] = [];
    for (const x of brandMenu) {
      if (x.id === packingId) continue;
      const m = categoryParents[x.category_id] ?? { id: x.category_id, name: x.category_name };
      if (!out.some((c) => c.id === m.id)) out.push(m);
    }
    return out;
  }, [brandMenu, packingId, categoryParents]);
  // Order screen: one category at a time (the first one to start with), like a till. Classic screen: "All" first.
  const activeTab = tab !== null && tabs.some((c) => c.id === tab) ? tab : inline && tabs.length > 1 ? tabs[0].id : null;
  // The chosen main category's sub-categories (only those with dishes on sale).
  const subTabs = useMemo(() => {
    if (activeTab === null) return [];
    const out: { id: string; name: string }[] = [];
    for (const x of brandMenu)
      if (x.id !== packingId && categoryParents[x.category_id]?.id === activeTab && !out.some((c) => c.id === x.category_id))
        out.push({ id: x.category_id, name: x.category_name });
    return out;
  }, [brandMenu, packingId, categoryParents, activeTab]);
  const activeSub = subTab !== null && subTabs.some((c) => c.id === subTab) ? subTab : null;
  const searching = search.trim() !== "";

  const categories = useMemo(() => {
    // A search looks in every category; otherwise the chosen tab (and sub-category tab) decides.
    const q = search.trim().toLowerCase();
    const filtered = brandMenu.filter((x) => {
      if (x.id === packingId || x.variantOf) return false;
      if (q) return x.name.toLowerCase().includes(q) || (x.short_name ?? "").toLowerCase().includes(q);
      if (activeTab === null) return true;
      const main = categoryParents[x.category_id]?.id ?? x.category_id;
      if (openOnly && !x.is_open_price) return false;
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
  }, [brandMenu, search, activeTab, activeSub, packingId, categoryParents, openOnly]);

  /** Items in the cart; a weighed line counts as one. */
  const itemCount = lines.reduce((s, l) => s + (l.item.byWeight ? 1 : l.qty), 0);
  useEffect(() => {
    onCartCount?.(itemCount);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [itemCount]);
  const qtyInCart = (productId: string) => lines.filter((l) => l.item.id === productId).reduce((s, l) => s + (l.item.byWeight ? 1 : l.qty), 0);
  // The same list goes to the live total and to the saved bill, so the two always agree.
  // The packing charge, when ticked, is one more item at the end: no note, no options, never held.
  const itemsPayload = () => {
    // An open-priced line carries the price typed at the till; no other line ever sends a price.
    const items: CartItem[] = lines.map((l) => ({
      product_id: l.item.id,
      qty: l.qty,
      options: l.options.map((o) => o.id),
      note: l.note.trim() || undefined,
      hold: !!l.hold,
      ...(l.openPrice != null ? { price: l.openPrice } : {}),
    }));
    if (packRule && packingTicked && lines.length > 0) items.push({ product_id: packRule.productId, qty: packingQty });
    return items;
  };
  /** The same list for the offline calculation. */
  const offlineLines = () => {
    // no_discount: the mark on the menu this screen was loaded with; offlineQuote also reads this device's offline copy.
    const out: { product_id: string; qty: number; unit_price: number; no_discount?: boolean }[] = lines.map((l) => ({
      product_id: l.item.id,
      qty: l.qty,
      unit_price: unitPrice(l),
      ...(l.item.no_discount ? { no_discount: true } : {}),
    }));
    if (packRule && packingTicked && lines.length > 0)
      out.push({ product_id: packRule.productId, qty: packingQty, unit_price: packRule.price, ...(packingNoDisc ? { no_discount: true } : {}) });
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
    if (lines.some((l) => l.openPrice != null)) return needsInternetText("open_price");
    try {
      const c = offlineQuote(snap, offlineLines(), snap.rights.discount ? discountAmt : 0, scChoice);
      const scOn = (scChoice ?? snap.settings.sc_default_on) && snap.settings.sc_percent > 0;
      return {
        subtotal: c.subtotal,
        discount: c.discount,
        discountable_subtotal: c.discountable_subtotal,
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
    if ((addTo && !billOrder) || lines.length === 0) {
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
        if (!billOrder) setError(null);
      } else {
        setQuote(null);
        if (!billOrder) setError(res.error);
      }
    }, 250);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cartKey, offline, snap]);

  // Stock warning strip: asks the database (online only, 600 ms after the cart stops changing) whether the order runs an
  // ingredient short. It never blocks anything: a failed or slow answer just means no strip. Replies out of order are ignored.
  const [stockWarn, setStockWarn] = useState<StockWarning[]>([]);
  const stockReq = useRef(0);
  const stockKey = JSON.stringify(lines.map((l) => [l.item.id, l.qty, l.options.map((o) => o.id).sort()]));
  useEffect(() => {
    const id = ++stockReq.current;
    if (!stockCheck || offline || lines.length === 0) {
      setStockWarn((w) => (w.length ? [] : w));
      return;
    }
    const t = setTimeout(async () => {
      try {
        const r = await stockWarnings(lines.map((l) => ({ product_id: l.item.id, qty: l.qty, options: l.options.map((o) => o.id) })));
        if (id === stockReq.current) setStockWarn(r.ok ? r.warnings : []);
      } catch {
        if (id === stockReq.current) setStockWarn([]);
      }
    }, 600);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stockKey, stockCheck, offline]);
  const stockStrip = offline ? null : stripText(stockWarn);
  const warnedIds = useMemo(() => (offline ? new Set<string>() : warnedProducts(stockWarn)), [stockWarn, offline]);

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
    // A dish sold in sizes: ask which size first, then carry on with that size.
    if (item.variants) {
      if (item.variants.length === 1) {
        const only = menu.find((x) => x.id === item.variants![0].id);
        if (only) tapItem(only);
      } else if (item.variants.length > 1) setSizing(item);
      return;
    }
    // Open price: ask for the price first. Needs the internet (the database checks the right) and the order.open_price right.
    if (item.is_open_price) {
      if (offline) return setError(needsInternetText("open_price"));
      if (!canOpenPrice) return setError(`Only a manager or owner can enter a price for ${item.name}. Ask them to bill it.`);
      setPricing(item);
      return;
    }
    // Sold by weight: ask for the weight (a scale label brings it already).
    if (item.byWeight) {
      setWeighing({ item });
      return;
    }
    if (item.groups.length > 0) {
      setPickPrice(null);
      setPicking(item);
    } else addLine(item, []);
  }
  /** The price typed for an open-priced dish: on to its options, or straight into the cart. */
  function priceChosen(item: MenuItem, price: number) {
    if (savedRef.current) return;
    if (item.groups.length > 0) {
      setPickPrice(price);
      setPicking(item);
    } else addLine(item, [], price);
  }
  /** A weighed line: each weighing is its own line. */
  function addWeighed(item: MenuItem, kg: number, key?: string) {
    if (savedRef.current) return;
    const q = Math.round(kg * 1000) / 1000;
    if (!(q >= 0.005)) return;
    setCart((c) => {
      if (key && c[key]) return { ...c, [key]: { ...c[key], qty: q } };
      const k = `${lineKey(item.id, [])}#w${Date.now()}`;
      return { ...c, [k]: { key: k, item, options: [], qty: q, note: "" } };
    });
  }
  /** The barcode scanner types the code and Enter into the search box. */
  function scan(code: string): boolean {
    const c = code.trim();
    if (!c) return false;
    const label = parseScaleLabel(c);
    if (label) {
      const item = menu.find((x) => x.barcode && x.barcode.replace(/^0+/, "") === label.itemCode.replace(/^0+/, ""));
      if (item) {
        if (item.byWeight) addWeighed(item, label.kg);
        else tapItem(item);
        return true;
      }
    }
    const item = menu.find((x) => x.barcode && x.barcode === c);
    if (item) {
      tapItem(item);
      return true;
    }
    return false;
  }
  function addLine(item: MenuItem, options: ChosenOption[], openPrice?: number) {
    const base = lineKey(item.id, options, openPrice);
    setCart((c) => {
      // Same item again goes onto the line without a note; a line with a kitchen
      // note ("no onion") stays separate so the kitchen sees exactly which one.
      // (An open-priced dish with another typed price is another line: the price is part of the key.)
      const plain = Object.values(c).find((l) => l.key.split("#")[0] === base && l.note.trim() === "" && !l.hold);
      if (plain) return { ...c, [plain.key]: { ...plain, qty: plain.qty + 1 } };
      const key = c[base] ? `${base}#${Date.now()}` : base;
      return { ...c, [key]: { key, item, options, qty: 1, note: "", ...(openPrice != null ? { openPrice } : {}) } };
    });
  }

  /** "Repeat last order": puts the newest kitchen round of this bill back into the cart at TODAY's menu prices (nothing is priced here). */
  async function repeatLastRound() {
    if (!addTo || savedRef.current || repeating) return;
    if (offline) return setError(needsInternetText("repeat_round"));
    setRepeating(true);
    setError(null);
    try {
      const res = await loadLastRound(addTo.id);
      if (!res.ok) return setError(res.error);
      if (res.lines.length === 0) return setError("Nothing has been sent to the kitchen on this bill yet.");
      const mapped = mapRoundToMenu(res.lines, menu, packing?.productId ?? null);
      // An open-priced dish needs a price typed again: it is not repeated.
      const needPrice = mapped.lines.filter((l) => l.item.is_open_price);
      const usable = mapped.lines.filter((l) => !l.item.is_open_price);
      const priceNote = needPrice.length > 0 ? `${needPrice.map((l) => l.item.name).join(", ")} ${needPrice.length === 1 ? "needs" : "need"} a new price: tap ${needPrice.length === 1 ? "it" : "them"} on the menu.` : null;
      if (usable.length === 0) return setError([mapped.message, priceNote].filter(Boolean).join(" ") || "None of those items can be repeated.");
      setCart((c) => {
        const next = { ...c };
        usable.forEach((l, i) => {
          const base = lineKey(l.item.id, l.options);
          // Weighed dishes are one line per weighing; others add onto the same dish + options if it is already in the cart.
          const key = l.item.byWeight ? `${base}#w${Date.now()}${i}` : base;
          const cur = next[key];
          next[key] = cur ? { ...cur, qty: cur.qty + l.qty } : { key, item: l.item, options: l.options, qty: l.qty, note: l.note };
        });
        return next;
      });
      const note = [mapped.message, priceNote].filter(Boolean).join(" ");
      if (note) setError(note);
    } catch {
      setError("Could not reach the server. Check the internet and try again.");
    } finally {
      setRepeating(false);
    }
  }
  /** The "+" on a row of the running bill: one more of that dish, same options and note, put in the list of new items. */
  async function addOneFrom(orderItemId: string) {
    if (!addTo || savedRef.current) return;
    if (offline) return setError(needsInternetText("add_to_bill"));
    setError(null);
    try {
      const res = await loadOneLine(addTo.id, orderItemId);
      if (!res.ok) return setError(res.error);
      const mapped = mapRoundToMenu([{ ...res.line, q: 1 }], menu, packing?.productId ?? null);
      const l = mapped.lines[0];
      if (!l) return setError(mapped.message || "That dish is not on the menu now.");
      if (l.item.is_open_price) return setError(`${l.item.name} needs a new price: tap it on the menu.`);
      setCart((c) => {
        const base = lineKey(l.item.id, l.options);
        const key = l.item.byWeight ? `${base}#w${Date.now()}` : base;
        const cur = c[key];
        return { ...c, [key]: cur ? { ...cur, qty: cur.qty + 1 } : { key, item: l.item, options: l.options, qty: 1, note: l.note } };
      });
    } catch {
      setError("Could not reach the server. Check the internet and try again.");
    }
  }
  const addOneRef = useRef(addOneFrom);
  addOneRef.current = addOneFrom;
  useEffect(() => {
    if (!addTo) return;
    const on = (e: Event) => {
      const id = (e as CustomEvent<string>).detail;
      if (typeof id === "string") void addOneRef.current(id);
    };
    window.addEventListener("sna-desk-plus", on);
    return () => window.removeEventListener("sna-desk-plus", on);
  }, [addTo]);
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
    clearDeskCarry();
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
    // On the single order screen the table was chosen outside this component and stays; the guests start again.
    setTableId(lockedTable?.id ?? null);
    setSeparateBill(!!lockedTable?.separate);
    setCovers("");
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

  // Table switch: restore what the previous table left (once), and show it as the cart.
  useEffect(() => {
    if (!deskKey) return;
    const carried = takeDeskCarry(deskKey, menu, packing?.productId ?? null, allowHold, canOpenPrice, deskTableId);
    if (!carried) return;
    if (Object.keys(carried.cart).length > 0) setCart((c) => (Object.keys(c).length > 0 ? c : carried.cart));
    if (carried.discount && canDiscount) {
      setDiscount(carried.discount);
      setDiscountReason(carried.reason);
    }
    if (carried.dropped > 0) setError(`${carried.dropped} item${carried.dropped === 1 ? "" : "s"} could not be brought to this table (menu changed or open price not allowed). Check the list before sending.`);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Offered to the order screen every render, so it always sees the current cart.
  useEffect(() => {
    if (!stashRef) return;
    stashRef.current = (destKey, toRunningBill) => {
      // A save is on its way or done: the items are (about to be) on the server, so they must not be copied anywhere.
      // (maybeSaved: a send got no reply, so it may be on the server; copying it to another table could make a second order.)
      if (savedRef.current || sending.current || maybeSaved) return "busy";
      if (lines.length === 0) return "empty";
      try {
        const kept: DeskCarriedLine[] = lines.map((l) => ({ p: l.item.id, o: l.options.map((o) => o.id), q: l.qty, n: l.note, h: !!l.hold, ...(l.openPrice != null ? { pr: l.openPrice } : {}) }));
        const withDiscount = !toRunningBill && canDiscount;
        sessionStorage.setItem(
          DESK_CARRY_KEY,
          JSON.stringify({ to: destKey, at: Date.now(), lines: kept, ...(withDiscount && discount ? { d: discount, dr: discountReason } : {}) }),
        );
        return "kept";
      } catch {
        // No storage on this device: nothing can follow.
        return "busy";
      }
    };
  });

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
    if (lines.some((l) => l.openPrice != null)) return setError(needsInternetText("open_price"));
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
    const { seq, number } = takeNumber(snap, lines.some((l) => l.item.liquor));
    const bill: OfflineBill = {
      client_id: crypto.randomUUID(),
      device_key: snap.device_key,
      seq,
      fy: snap.series.fy,
      number,
      created_at: new Date().toISOString(),
      order_type: orderType,
      guest: guest && (guest.name || guest.phone || guest.address) ? guest : null,
      // Name and phone again as plain fields: the server finds or creates the customer when the bill syncs, so points are earned then.
      ...(guest?.phone ? { guest_phone: guest.phone } : {}),
      ...(guest?.name ? { guest_name: guest.name } : {}),
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
      // When this till last copied the menu: lets the server accept prices that were right then.
      snapshot_at: snap.taken_at,
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
    if (!discountParsed.ok) return setError(discountParsed.message);
    if (mixedLiquor) return setError("Liquor and food go on separate bills. Remove the food or the drinks, save this bill, then bill the rest.");
    if (!quote || quoting) return setError("Please wait a moment — the total is being checked.");
    if (needSeparate) return setError(`Table ${chosenTable?.number ?? ""} already has an open bill. Add to it, or tick “Start a separate bill for this table”.`);
    const guestsProblem = coversError({ askCovers, orderType, adding: !!addTo, offline, text: covers });
    if (guestsProblem) return setError(guestsProblem);
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
      // Guests are asked on the single order screen only; the classic screen sends none, as before.
      ...(askCovers && orderType === "dine_in" && coversNum ? { covers: coversNum } : {}),
    };
    // Where the bill is, for the kitchen ticket: "Table 5", or "Takeaway · Name".
    const typeText = orderTypeLabel[orderType] ?? "";
    const whereText =
      orderType === "dine_in" && chosenTable ? `Table ${chosenTable.number}` : orderType !== "dine_in" && guestName.trim() ? `${typeText} · ${guestName.trim()}` : typeText;
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
      // On the single order screen the bill opens beside the menu (/pos?bill=...) and the kitchen ticket prints in an overlay.
      const next =
        mode === "split"
          ? inline
            ? `/pos?bill=${res.orderId}&pay=split`
            : `/bills/${res.orderId}?pay=split`
          : mode === "unpaid"
            ? `/pos/kot/${res.orderId}`
            : inline
              ? `/pos?bill=${res.orderId}&print=1`
              : `/pos/receipt/${res.orderId}?print=1`;
      savedRef.current = true;
      clearDeskCarry();
      setMaybeSaved(false);
      setSaved(next);
      // Winsar NC KOT: the bill is marked no-charge the moment it is saved. If that is refused (no manager right),
      // the bill stays a normal one and the message says so, rather than leaving a free bill behind by accident.
      if (mode === "unpaid" && ncKot && ncReason.trim().length >= 3) {
        try {
          const nc = await makeComplimentary({ orderId: res.orderId, kind: "complimentary", reason: ncReason.trim(), chargeTo: ncCharge || null });
          if (!nc.ok) setError(`The order was saved, but it is NOT no-charge: ${cleanMessage(nc.error)}`);
        } catch {
          setError("The order was saved, but the no-charge mark could not be set. Open the bill and set it there.");
        }
      }
      if (mode === "unpaid" && onKotDone) onKotDone({ orderId: res.orderId, billNumber: res.billNumber, where: whereText, token: res.tokenNo, kind: "new" });
      else router.push(next);
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
    if (offline) return setError(needsInternetText("add_to_bill"));
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
      clearDeskCarry();
      // The added items go to the kitchen: print their KOT here, then back to the bill.
      setSaved(`/pos/kot/${addTo.id}?then=bill`);
      if (onKotDone) onKotDone({ orderId: addTo.id, billNumber: addTo.billNumber, where: addTo.where ?? (addTo.table ? `Table ${addTo.table}` : ""), token: addTo.token ?? null, kind: "add" });
      else router.push(`/pos/kot/${addTo.id}?then=bill`);
    });
  }

  const listBox = (
          <div className={merged ? "border-t px-2 py-1" : "flex-1 overflow-y-auto px-4 py-2"} style={merged ? { borderColor: "var(--color-line)" } : undefined}>
            {merged && lines.length > 0 && (
              <div className="-mx-2 mb-1 px-2 py-1 text-center text-[11px] font-bold text-white" style={{ background: "#1D4F9F" }}>
                New items · not sent yet
              </div>
            )}
            {mixedLiquor && (
              <p className="mb-2 rounded-lg px-3 py-2 text-xs font-semibold" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                This order has liquor and food. They go on separate bills: remove one kind, save, then bill the other.
              </p>
            )}
            {inline && lines.length > 0 && (
              <div
                className="mb-1 flex items-center gap-2 border-b pb-1 text-[11px] font-bold uppercase tracking-wide"
                style={{ borderColor: "var(--color-line)", color: "var(--color-ink-3)" }}
                aria-hidden="true"
              >
                <span className="min-w-0 flex-1">Item</span>
                <span className="w-24 text-center">Qty</span>
                <span className="w-20 text-right">Price</span>
              </div>
            )}
            {lines.length === 0 ? (
              merged ? null : <p className="py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                No items yet.
              </p>
            ) : (
              <>
              <ul>
                {lines.map((l) => (
                  <li key={l.key} className="border-b py-2 last:border-0" style={{ borderColor: "var(--color-line)", background: tableOrder && pickedLine === l.key ? "var(--color-brand-soft)" : undefined }}>
                  <div className="flex items-center gap-2">
                    <div
                      className={`min-w-0 flex-1${tableOrder ? " cursor-pointer" : ""}`}
                      onClick={tableOrder ? () => setPickedLine((k) => (k === l.key ? null : l.key)) : undefined}
                      title={tableOrder ? "Tap to choose this line for the special instruction" : undefined}
                    >
                      <div className="truncate text-sm font-medium">{l.item.name}</div>
                      {l.options.length > 0 && (
                        <div className="truncate text-[11px]" style={{ color: "var(--color-ink-2)" }}>
                          {l.options.map((o) => o.name).join(", ")}
                        </div>
                      )}
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {m(unitPrice(l))}
                        {l.openPrice != null && " · open price"}
                        {noDisc(l) && (
                          <span className="ml-1.5 rounded px-1 text-[10px] font-semibold" style={{ background: "var(--color-surface-2, #eee)", color: "var(--color-ink-2)" }} title="This item cannot be discounted">
                            No discount
                          </span>
                        )}
                        {warnedIds.has(l.item.id) && (
                          <span className="ml-1.5 inline-block h-2 w-2 rounded-full align-middle" style={{ background: "var(--color-warn)" }} title="An ingredient for this dish is running short" aria-label="Stock is short for this dish" />
                        )}
                      </div>
                    </div>
                    <div className="flex items-center gap-1.5">
                      {l.item.byWeight ? (
                        <>
                          <button onClick={() => setWeighing({ item: l.item, key: l.key, kg: l.qty })} className="rounded-md border px-2 py-1 text-sm font-semibold" style={{ borderColor: "var(--color-line)" }} aria-label={`Change the weight of ${l.item.name}`}>
                            {qtyText(l.qty, true)}
                          </button>
                          <button onClick={() => step(l.key, -l.qty)} className="grid h-8 w-8 place-items-center rounded-md border text-base" style={{ borderColor: "var(--color-line)" }} aria-label={`Remove ${l.item.name}`}>
                            ✕
                          </button>
                        </>
                      ) : (
                        <>
                          <button onClick={() => step(l.key, -1)} className="grid h-8 w-8 place-items-center rounded-md border text-base" style={{ borderColor: "var(--color-line)" }} aria-label={`One less ${l.item.name}`}>
                            −
                          </button>
                          <span className="w-5 text-center text-sm font-semibold">{l.qty}</span>
                          <button onClick={() => step(l.key, 1)} className="grid h-8 w-8 place-items-center rounded-md border text-base" style={{ borderColor: "var(--color-line)" }} aria-label={`One more ${l.item.name}`}>
                            +
                          </button>
                        </>
                      )}
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
                      {merged && lines.length > 0 && (
              <div className="-mx-2 mt-1 flex items-center justify-between border-t px-2 pt-1 text-xs font-bold" style={{ borderColor: "var(--color-line)", color: "#1D4F9F" }}>
                <span>New items · {itemCount}</span>
                <span title="Before the tax on these items; the bill total is worked out when they are sent">{m(addSubtotal)}</span>
              </div>
            )}
</div>
  );

  return (
    <div className={inline ? `grid gap-3 sm:grid-cols-[270px_minmax(0,1fr)] lg:grid-cols-[320px_minmax(0,1fr)] xl:grid-cols-[360px_minmax(0,1fr)]${tableOrder ? " pb-16 sm:h-[calc(100dvh-8.5rem)] sm:overflow-hidden" : ""}${billOrder ? " pb-16 xl:contents" : ""}` : "grid gap-4 lg:grid-cols-[1fr_360px]"}>
      <div className={tableOrder ? "min-h-0 overflow-y-auto pr-1" : billOrder ? "min-h-0 overflow-y-auto pr-1 xl:col-start-2 xl:row-span-2 xl:row-start-1 xl:h-[calc(100dvh-8.5rem)]" : undefined}>
        <div className="mb-3 flex flex-wrap items-center gap-x-3">
          <h1 className={inline ? "text-base font-bold tracking-tight" : "text-xl font-bold tracking-tight"}>
            {addTo ? `${addTo.table ? `Table ${addTo.table}: add items to bill` : "Add items to bill"} ${addTo.billNumber}` : lockedTable ? (inline ? `Table : ${lockedTable.number}  ·  Cover : ${coversNum ?? 0}${ncKot ? "  ·  NC KOT" : ""}` : `Table ${lockedTable.number}: new order`) : deskKey ? "Counter: new order" : "Billing"}
          </h1>
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
          <span className={inline ? "hidden" : "text-xs"} style={{ color: "var(--color-ink-3)" }}>
            Tap an item to add it · prices {pricesIncludeTax ? `include ${taxName}` : `before ${taxName}`}
          </span>
          {customerDisplay && (
            <button
              type="button"
              className="btn border ml-auto text-xs"
              style={{ borderColor: "var(--color-line)", color: "var(--color-brand-strong)" }}
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
        <div className="mb-3 flex gap-2">
          <input
            className="field min-w-0"
            style={{ flex: "1 1 0%", width: "auto" }}
            placeholder="Search the menu or scan a barcode…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onKeyDown={(e) => {
              // A barcode scanner types the code and presses Enter.
              if (e.key === "Enter" && scan(search)) {
                e.preventDefault();
                setSearch("");
              }
            }}
            autoComplete="off"
          />
          <input
            className="field shrink-0"
            style={{ width: 150, flex: "0 0 150px" }}
            aria-label="Item code"
            placeholder="Item code ⏎"
            value={code}
            maxLength={20}
            onChange={(e) => {
              setCode(e.target.value);
              setCodeMsg(null);
            }}
            onKeyDown={(e) => {
              if (e.key !== "Enter") return;
              e.preventDefault();
              const c = code.trim();
              if (!c) return;
              const item = menu.find((x) => x.barcode && x.barcode.trim().toLowerCase() === c.toLowerCase());
              if (item) {
                tapItem(item);
                setCode("");
                setCodeMsg(null);
              } else if (scan(c)) {
                setCode("");
                setCodeMsg(null);
              } else setCodeMsg(`No item has the code “${c}”. Set an item code on the Menu screen.`);
            }}
            autoComplete="off"
          />
        </div>
        {codeMsg && (
          <p className="-mt-2 mb-3 text-xs font-semibold" role="status" style={{ color: "var(--color-bad)" }}>
            {codeMsg}
          </p>
        )}
        {brandTabs.length > 1 && (
          <div className="mb-3 flex gap-2 overflow-x-auto pb-1" role="group" aria-label="Brands">
            {[{ id: null as string | null, name: "All brands" }, ...brandTabs].map((b) => {
              const on = activeBrand === b.id;
              return (
                <button
                  key={b.id ?? "all"}
                  type="button"
                  aria-pressed={on}
                  onClick={() => {
                    setBrand(b.id);
                    setTab(null);
                    setSubTab(null);
                  }}
                  className="min-h-[40px] shrink-0 whitespace-nowrap rounded-lg border px-3 text-sm font-bold"
                  style={
                    winStyle
                      ? { borderColor: "#1D6FD0", background: on ? "#1D6FD0" : "#4DABF7", color: "#FFFFFF" }
                      : {
                          borderColor: on ? "var(--color-ink)" : "var(--color-line)",
                          background: on ? "var(--color-ink)" : "var(--color-surface)",
                          color: on ? "var(--color-surface)" : "var(--color-ink-2)",
                        }
                  }
                >
                  {b.name}
                </button>
              );
            })}
          </div>
        )}
        {inline && canOpenPrice && !addTo && !tableOrder && (
          <div className="mb-2 flex justify-end">
            <button type="button" className="rounded-md px-3 py-1 text-xs font-bold text-white" style={{ background: "#E8590C" }} onClick={() => { setQuickErr(null); setQuickOpen(true); }}>
              Open +
            </button>
          </div>
        )}
        {(tabs.length > 1 || Object.keys(categoryParents).length > 0) && (
          <div className="mb-4 flex gap-2 overflow-x-auto pb-1" role="group" aria-label="Menu categories">
            {[...(inline && tabs.length > 1 ? [] : [{ id: null as string | null, name: "All" }]), ...tabs].map((c) => {
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
                  className={inline ? "min-h-[48px] min-w-[96px] shrink-0 whitespace-nowrap rounded-lg border px-4 text-sm font-bold uppercase" : "min-h-[44px] shrink-0 whitespace-nowrap rounded-full border px-4 text-sm font-semibold"}
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
        {!searching && !winStyle && topSellerIds.length > 0 && (
          <TopSellers ids={topSellerIds} menu={menu} onTap={tapItem} />
        )}
        <div className="space-y-5">
          {categories.map((cat) => (
            <section key={cat.id}>
              <h2 className="mb-2 text-xs font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
                {cat.name}
              </h2>
              <div className={winStyle ? "grid grid-cols-2 gap-1.5 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5" : inline ? "grid grid-cols-2 gap-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5" : "grid grid-cols-2 gap-2 sm:grid-cols-3"}>
                {cat.items.map((item) => {
                  const inCart = item.variants ? item.variants.reduce((s, v) => s + qtyInCart(v.id), 0) : qtyInCart(item.id);
                  return (
                    <button
                      key={item.id}
                      onClick={() => tapItem(item)}
                      className={`tap card relative flex flex-col items-start justify-between gap-1 text-left transition active:scale-[0.98] ${winStyle ? "min-h-[58px] p-2" : "p-3"}`}
                      style={
                        winStyle
                          ? { borderColor: inCart ? "var(--color-brand)" : "#DDD3C8", background: inCart ? "var(--color-brand-soft)" : "#F4EFE8" }
                          : { borderColor: inCart ? "var(--color-brand)" : "var(--color-line)" }
                      }
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
                        {item.listPrice != null && !item.variants?.length && (
                          <s className="mr-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                            {m(item.listPrice)}
                          </s>
                        )}
                        {item.variants?.length ? `from ${m(item.variants[0].price)}` : item.is_open_price ? "open price" : m(item.price)}
                        {item.byWeight && "/kg"}
                        {item.left != null && (
                          <span className="ml-1 text-[11px] font-semibold" style={{ color: item.left - qtyInCart(item.id) > 0 ? "var(--color-ink-3)" : "var(--color-bad)" }}>
                            · {Math.max(0, item.left - qtyInCart(item.id))} left
                          </span>
                        )}
                        {item.variants && item.variants.length > 1 && (
                          <span className="ml-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                            · {item.variants.length} sizes
                          </span>
                        )}
                        {item.isCombo && (
                          <span className="ml-1 rounded px-1 text-[10px] font-bold uppercase" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)" }}>
                            combo
                          </span>
                        )}
                        {!item.variants && !item.isCombo && item.groups.length > 0 && (
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
          className={`fixed inset-x-3 bottom-3 z-40 flex items-center justify-between rounded-2xl px-4 py-3 text-sm font-bold shadow-lg ${inline ? "sm:hidden" : "lg:hidden"}`}
          style={{ background: "var(--color-brand)", color: "#fff" }}
          onClick={() => document.getElementById("cart")?.scrollIntoView({ behavior: "smooth" })}
        >
          <span>
            View order · {whereLabel ? `${whereLabel} · ` : ""}{itemCount} item{itemCount === 1 ? "" : "s"}
          </span>
          <span>{quote ? m(due) : m(addSubtotal)}</span>
        </button>
      )}

      <div id="cart" className={inline ? (tableOrder ? "min-h-0 scroll-mt-4 sm:order-first" : billOrder ? "min-h-0 scroll-mt-4 pb-20 sm:order-first xl:col-start-1 xl:row-start-2 xl:pb-0" : "scroll-mt-4 pb-20 sm:order-first sm:sticky sm:top-2 sm:self-start sm:pb-0") : "scroll-mt-4 pb-20 lg:sticky lg:top-4 lg:self-start lg:pb-0"}>
        <div className={`card flex flex-col ${winStyle ? "h-full" : "max-h-[calc(100vh/var(--z)_-_2rem)]"}`}>
          <div className="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 border-b px-4 py-3" style={{ borderColor: "var(--color-line)" }}>
            <div className="whitespace-nowrap text-sm font-bold">{addTo ? "Items to add" : "Current bill"}</div>
            {addTo ? (
              <span className="flex items-center gap-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                {!offline && (
                  <button
                    type="button"
                    className="whitespace-nowrap rounded-md border px-2 py-1 text-xs font-semibold"
                    style={{ borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
                    onClick={repeatLastRound}
                    disabled={repeating || pending || !!saved}
                    title="Put the items of the last kitchen round back in the list, at today's prices"
                  >
                    {repeating ? "Loading…" : "Repeat last order"}
                  </button>
                )}
                {addTo.table ? `Table ${addTo.table} · ` : ""}bill {addTo.billNumber}
              </span>
            ) : lockedTable ? (
              <span className="text-xs font-semibold" style={{ color: "var(--color-ink-2)" }}>
                <Dual text="Dine in" /> · T{lockedTable.number}
              </span>
            ) : (
              <div className="flex overflow-hidden rounded-lg border" style={{ borderColor: "var(--color-line)" }}>
                {kinds.map((t) => (
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

          {!addTo && lockedTable && (
            <div className="border-b px-4 py-2 text-xs" style={{ borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}>
              New bill for table <b>{lockedTable.number}</b>
              {lockedTable.separate ? ": a separate bill, this table already has one." : "."}
              {offline && <span className="mt-1 block" style={{ color: "var(--color-warn)" }}>No internet: a bill made now is paid at once and is not put on the table.</span>}
            </div>
          )}

          {askCovers && !addTo && !tableOrder && orderType === "dine_in" && !offline && (
            <div className="border-b px-4 py-2" style={{ borderColor: "var(--color-line)" }}>
              <div className="flex items-center justify-between gap-2">
                <label htmlFor="covers" className="text-xs font-semibold">
                  Guests
                </label>
                <div className="flex items-center gap-1.5">
                  <button
                    type="button"
                    className="grid h-9 w-9 place-items-center rounded-md border text-base"
                    style={{ borderColor: "var(--color-line)" }}
                    aria-label="One guest less"
                    disabled={coversNum === null || coversNum <= 1}
                    onClick={() => setCovers(String(Math.max(1, (coversNum ?? 1) - 1)))}
                  >
                    −
                  </button>
                  <input
                    id="covers"
                    className="field h-9 w-14 text-center text-sm"
                    inputMode="numeric"
                    placeholder="0"
                    aria-label="Number of guests"
                    value={covers}
                    maxLength={2}
                    autoComplete="off"
                    onChange={(e) => setCovers(e.target.value.replace(/\D/g, "").slice(0, 2))}
                  />
                  <button
                    type="button"
                    className="grid h-9 w-9 place-items-center rounded-md border text-base"
                    style={{ borderColor: "var(--color-line)" }}
                    aria-label="One guest more"
                    disabled={coversNum !== null && coversNum >= 99}
                    onClick={() => setCovers(String(Math.min(99, (coversNum ?? 0) + 1)))}
                  >
                    +
                  </button>
                </div>
              </div>
              {coversNum === null && lines.length > 0 && (
                <p className="mt-1 text-[11px]" style={{ color: "var(--color-warn)" }}>
                  Enter the number of guests before you send the order.
                </p>
              )}
            </div>
          )}

          {!addTo && !inline && orderType === "dine_in" && tables.length > 0 && (
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
              {regular && regularChipText(regular, true) && (
                <div className="mt-1.5 text-xs font-semibold" style={{ color: "var(--color-brand-strong)" }} data-testid="terminal-regular-chip">
                  {regular.name ? `${regular.name} · ` : ""}
                  {regularChipText(regular, true)}
                </div>
              )}
              {favs && favs.favourites.length > 0 && (
                <div className="mt-1 flex flex-wrap items-center gap-1.5" role="group" aria-label="Favourite dishes of this guest">
                  <span className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    Usually orders:
                  </span>
                  {favs.favourites.map((f) => {
                    const item = menu.find((x) => x.id === f.productId);
                    if (!item) return null;
                    return (
                      <button
                        key={f.productId}
                        type="button"
                        className="rounded-full border px-2.5 py-1 text-xs font-semibold"
                        style={{ borderColor: "var(--color-line)", background: "var(--color-brand-soft)", color: "var(--color-brand-strong)" }}
                        onClick={() => tapItem(item)}
                      >
                        + {f.name}
                      </button>
                    );
                  })}
                </div>
              )}
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

          {merged ? (slot ? createPortal(listBox, slot) : null) : listBox}
          {merged && totalSlot && quote && lines.length > 0
            ? createPortal(
                <div className="mt-0.5 flex justify-between text-xs font-bold" style={{ color: "#1D4F9F" }} title="An estimate: the bill's tax, service charge and rounding are worked out again when the items are sent">
                  <span>With new items (est.)</span>
                  <span>{m(Math.round((Number(totalSlot.dataset.total ?? 0) + quote.grand_total) * 100) / 100)}</span>
                </div>,
                totalSlot,
              )
            : null}

          {addTo ? (
            <div className="border-t px-4 py-3" style={{ borderColor: "var(--color-line)" }}>
              {stockStrip && (
                <div className="mb-2 rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                  {stockStrip.lines.map((t) => (
                    <div key={t}>{t}</div>
                  ))}
                  {stockStrip.more > 0 && <div>and {stockStrip.more} more.</div>}
                  <div className="font-semibold">{stockStrip.footer}</div>
                </div>
              )}
              <div className="flex justify-between text-sm">
                <span style={{ color: "var(--color-ink-3)" }}>New items {pricesIncludeTax ? "" : `(before ${taxName})`}</span>
                <span className="font-semibold">{m(addSubtotal)}</span>
              </div>
              <p className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                The bill&rsquo;s tax, service charge and total are worked out again when you add. A new kitchen ticket is sent for these items only.
              </p>
              {offline && !saved && (
                <p className="mt-3 rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                  No connection. {needsInternetText("add_to_bill")}
                </p>
              )}
              {error && !saved && <ErrorBox text={error} />}
              {saved && <SavedBox text="Added and sent to the kitchen. Printing the KOT…" quiet={inline} slow={savedSlow} onOpen={() => router.push(saved)} />}
              <div className="mt-3 flex gap-2">
                {!inline && (
                  <button onClick={() => router.push(`/bills/${addTo.id}`)} disabled={pending} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                    Back to bill
                  </button>
                )}
                {inline && (
                  <button onClick={clearAll} disabled={pending || lines.length === 0 || !!saved} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                    Clear
                  </button>
                )}
                <button onClick={submitAdd} disabled={pending || lines.length === 0 || offline || !!saved} className="btn btn-primary flex-1">
                  {pending ? "Adding…" : `KOT · add ${itemCount || ""} to bill`}
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
                  {(canDiscount || canPay) && !senior && !tableOrder && (
                    <div className="flex items-center gap-2">
                      <label className="text-xs font-medium" style={{ color: "var(--color-ink-2)" }} htmlFor="discount">
                        Discount
                      </label>
                      <input
                        id="discount"
                        className="field h-9 flex-1 text-sm"
                        inputMode="text"
                        placeholder={nothingDiscountable ? "Not allowed on these items" : "Amount or 10%"}
                        value={nothingDiscountable ? "" : discount}
                        disabled={nothingDiscountable}
                        onChange={(e) => setDiscount(e.target.value)}
                      />
                    </div>
                  )}
                  {(canDiscount || canPay) && !senior && !tableOrder && !nothingDiscountable && presetsHere.length > 0 && (
                    <div className="flex flex-wrap gap-1.5" role="group" aria-label="Saved discounts">
                      {presetsHere.map((x) => (
                        <button
                          key={x.id}
                          type="button"
                          className="tap rounded-full border px-3 py-1.5 text-xs font-medium"
                          style={{ borderColor: "var(--color-line)", background: discountReason === x.name ? "var(--color-brand-soft, #e6f2ec)" : "transparent" }}
                          onClick={() => {
                            setDiscount(x.kind === "percent" ? `${x.value}%` : String(x.value));
                            setDiscountReason(x.name);
                          }}
                        >
                          {x.name} {x.kind === "percent" ? `${x.value}%` : m(x.value)}
                        </button>
                      ))}
                    </div>
                  )}
                  {(canDiscount || canPay) && !senior && nothingDiscountable && (
                    <p className="text-xs" role="status" style={{ color: "var(--color-ink-2)" }}>
                      None of these items can be discounted.
                    </p>
                  )}
                  {(canDiscount || canPay) && !senior && !nothingDiscountable && discountBase < wholeBase && (
                    <p className="text-xs" role="status" style={{ color: "var(--color-ink-2)" }}>
                      Discount applies to {m(discountBase)} of {m(wholeBase)}. Some items cannot be discounted.
                    </p>
                  )}
                  {(canDiscount || canPay) && !senior && !discountParsed.ok && (
                    <p className="text-xs" role="alert" style={{ color: "var(--color-bad)" }}>
                      {discountParsed.message}
                    </p>
                  )}
                  {(canDiscount || canPay) && !senior && discountParsed.ok && discountParsed.percent !== null && (
                    <p className="text-xs" role="status" style={{ color: "var(--color-ink-2)" }}>
                      {discountParsed.percent}% = {m(discountParsed.amount)}
                    </p>
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

              {stockStrip && (
                <div className="mb-2 rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                  {stockStrip.lines.map((t) => (
                    <div key={t}>{t}</div>
                  ))}
                  {stockStrip.more > 0 && <div>and {stockStrip.more} more.</div>}
                  <div className="font-semibold">{stockStrip.footer}</div>
                </div>
              )}
              {tableOrder && lines.length > 0 && (
                <div className="mb-2" aria-label="Special instruction">
                  <div className="mb-1 text-[11px] font-semibold" style={{ color: "var(--color-ink-3)" }}>
                    Special instruction for <b>{(lines.find((l) => l.key === pickedLine) ?? lines[lines.length - 1]).item.name}</b>
                    {lines.length > 1 && !pickedLine ? " — tap a line above to choose another" : ""}
                  </div>
                  <div className="flex flex-wrap gap-1">
                    {["Less spicy", "Extra spicy", "No onion", "No garlic", "Less oil", "Less sugar", "Pack separately", "Hurry"].map((sp) => {
                      const last = lines.find((l) => l.key === pickedLine) ?? lines[lines.length - 1];
                      const has = last.note.split(", ").includes(sp);
                      return (
                        <button
                          key={sp}
                          type="button"
                          className="rounded-md border px-2 py-1 text-[11px] font-semibold"
                          style={{
                            borderColor: has ? "var(--color-brand)" : "var(--color-line)",
                            background: has ? "var(--color-brand)" : "var(--color-surface)",
                            color: has ? "#fff" : "var(--color-ink-2)",
                          }}
                          onClick={() => {
                            const parts = last.note.split(", ").filter(Boolean);
                            setNote(last.key, (has ? parts.filter((x) => x !== sp) : [...parts, sp]).join(", "));
                          }}
                        >
                          {sp}
                        </button>
                      );
                    })}
                  </div>
                </div>
              )}
              <dl className="space-y-1 text-sm" aria-live="polite">
                {tableOrder && lines.length > 0 && (
                  <div className="flex justify-between pb-1 text-xs font-bold" style={{ color: "var(--color-brand-strong)" }}>
                    <dt>QTY : {lines.reduce((n, l) => n + l.qty, 0)}</dt>
                    <dd />
                  </div>
                )}
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

              {!tableOrder && (
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
              )}

              {maybeSaved && !saved && (
                <ErrorBox text="The connection dropped while saving, so this bill may already be saved. Look in Bills before you save it again. To bill offline now, press the button again." />
              )}
              {error && !saved && <ErrorBox text={error} />}
              {saved && <SavedBox text={saved.startsWith("/pos/kot/") ? "Sent to the kitchen. Printing the KOT…" : "Saved. Opening the bill…"} quiet={inline && saved.startsWith("/pos/kot/")} slow={savedSlow} onOpen={() => router.push(saved)} onNext={startNextBill} />}
              {needSeparate && lines.length > 0 && (
                <p className="mt-3 rounded-lg px-3 py-2 text-xs" role="status" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
                  Table {chosenTable?.number} already has an open bill. Add to it, or tick &ldquo;Start a separate bill for this table&rdquo; above.
                </p>
              )}

              <div className={`mt-3 flex gap-2${tableOrder ? " hidden" : ""}`}>
                <button onClick={clearAll} disabled={pending || lines.length === 0 || !!saved} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                  Clear
                </button>
                {canPay && !tableOrder ? (
                  <>
                    <button
                      onClick={() => submit("unpaid")}
                      disabled={pending || quoting || !quote || !discountParsed.ok || needSeparate || !!saved}
                      className="btn border px-4 text-base font-bold"
                      style={{ borderColor: "var(--color-brand)", background: "var(--color-surface)", color: "var(--color-brand-strong, var(--color-brand))" }}
                      title="Send the order to the kitchen and print the KOT. The bill stays open: print it and take the payment later."
                    >
                      KOT
                    </button>
                    <button onClick={() => submit("pay")} disabled={pending || quoting || !quote || !discountParsed.ok || needSeparate || !!saved} className="btn btn-pay flex-1 text-base">
                      {pending ? "Saving…" : <Dual text="Charge" />}
                      {!pending && quote ? ` ${m(due)}` : ""}
                    </button>
                  </>
                ) : (
                  <>
                  <button
                    onClick={() => submit("unpaid")}
                    disabled={pending || quoting || !quote || !discountParsed.ok || needSeparate || !!saved}
                    className="btn btn-primary min-w-0 flex-1 whitespace-nowrap px-2 text-sm"
                    title={tableOrder ? "Send the order to the kitchen and print the KOT. The bill stays open on the table; settle it from the bill." : "Send the order to the kitchen and print the KOT. The cashier takes the payment later."}
                  >
                    {pending ? "Saving…" : tableOrder ? "Save KOT" : "KOT"}
                  </button>
                  {tableOrder && (
                    <button
                      onClick={() => router.push("/pos")}
                      disabled={pending}
                      className="btn border shrink-0 px-3 text-sm"
                      style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}
                    >
                      Back
                    </button>
                  )}
                  </>
                )}
              </div>
              {canPay && !tableOrder ? (
                <button
                  onClick={() => submit("split")}
                  disabled={pending || quoting || !quote || !discountParsed.ok || needSeparate || !!saved}
                  className="mt-2 w-full text-center text-xs font-semibold"
                  style={{ color: "var(--color-brand-strong)" }}
                >
                  Split payment (part cash, part card/UPI, or share between people)
                </button>
              ) : tableOrder ? null : (
                <p className="mt-2 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {tableOrder && canPay ? "" : "The cashier takes the payment."}
                </p>
              )}
            </div>
          )}
        </div>
      </div>

      {winStyle && (
        <div
          className="fixed inset-x-0 bottom-0 z-40 flex items-center gap-1.5 border-t px-2 py-2"
          style={{ background: "var(--color-surface)", borderColor: "var(--color-line)" }}
          role="group"
          aria-label="Order buttons"
        >
          <WinBtn tone="#E8590C" onClick={() => { setOpenOnly(false); document.querySelector<HTMLInputElement>('input[placeholder^="Search the menu"]')?.focus(); }}>
            Direct
          </WinBtn>
          <WinBtn tone="#E8590C" disabled={!canOpenPrice} title={canOpenPrice ? "Make a new dish in the group being shown" : "Needs the open-price right"} onClick={() => { setQuickErr(null); setQuickOpen(true); }}>
            Open +
          </WinBtn>
          <WinBtn tone={openOnly ? "#5F3DC4" : "#E8590C"} onClick={() => setOpenOnly((v) => !v)} title="Show only the open-price dishes of this group">
            Open list
          </WinBtn>
          <WinBtn tone="#E8590C" disabled={!addTo || repeating || pending || !!saved} title={addTo ? "Put the items of the last kitchen round back in the list" : "Only on a table that already has a round"} onClick={repeatLastRound}>
            {repeating ? "…" : "Repeat"}
          </WinBtn>
          <span className="flex-1" />
          {billOrder ? (
            <WinBtn tone="#1D4F9F" title="Open the Check screen of this bill: split, discount, settle" onClick={() => window.dispatchEvent(new Event("sna-desk-check"))}>
              Check ✓
            </WinBtn>
          ) : (
            <WinBtn tone="#1D4F9F" disabled={!deskTableId} title={deskTableId ? "Open the bill of this table" : "The bill opens once the first KOT is saved"} onClick={() => deskTableId && router.push("/pos")}>
              Check ✓
            </WinBtn>
          )}
          <WinBtn
            tone="#2E7D32"
            disabled={billOrder ? pending || offline || !!saved || lines.length === 0 : pending || quoting || !quote || !discountParsed.ok || needSeparate || !!saved || lines.length === 0}
            onClick={() => (billOrder ? submitAdd() : submit("unpaid"))}
          >
            {pending ? "Saving…" : "Save Kot"}
          </WinBtn>
          <WinBtn tone="#6B7280" disabled={pending} onClick={() => router.push("/pos")}>
            ‹ Back
          </WinBtn>
        </div>
      )}

      {quickOpen && (
        <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" role="dialog" aria-label="Open item creation">
          <div className="w-full max-w-sm rounded-xl p-4" style={{ background: "var(--color-surface)" }}>
            <div className="mb-3 text-center text-sm font-bold" style={{ color: "#6D28D9" }}>Open Item Creation</div>
            <p className="mb-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
              Group: {(subTabs.find((c) => c.id === activeSub)?.name ?? tabs.find((c) => c.id === activeTab)?.name) || "choose a group first"}. The dish is saved on the menu with the same tax as the other dishes in the group.
            </p>
            <label className="text-xs font-semibold" htmlFor="qd-name">Open item name</label>
            <input id="qd-name" className="field mb-2 h-10 w-full text-sm" value={quickName} maxLength={60} onChange={(e) => setQuickName(e.target.value)} />
            <label className="text-xs font-semibold" htmlFor="qd-rate">Sale rate</label>
            <input id="qd-rate" className="field mb-2 h-10 w-full text-sm" inputMode="decimal" value={quickPrice} onChange={(e) => setQuickPrice(e.target.value.replace(/[^0-9.]/g, ""))} />
            {quickErr && <p className="mb-2 text-xs" style={{ color: "var(--color-bad)" }}>{quickErr}</p>}
            <div className="flex justify-end gap-2">
              <button type="button" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setQuickOpen(false)}>Back</button>
              <button
                type="button"
                className="btn btn-primary px-6 text-sm"
                disabled={quickBusy || quickName.trim().length < 2 || !(Number(quickPrice) >= 0) || quickPrice === ""}
                onClick={async () => {
                  const cat = activeSub ?? activeTab;
                  if (!cat) return setQuickErr("Choose a group first.");
                  setQuickBusy(true);
                  setQuickErr(null);
                  try {
                    const res = await createQuickDish({ name: quickName, price: Number(quickPrice), categoryId: cat });
                    if (!res.ok) return setQuickErr(res.error);
                    setQuickOpen(false);
                    setQuickName("");
                    setQuickPrice("");
                    router.refresh();
                  } catch {
                    setQuickErr("Could not save. Check the internet and try again.");
                  } finally {
                    setQuickBusy(false);
                  }
                }}
              >
                {quickBusy ? "Saving…" : "Save"}
              </button>
            </div>
          </div>
        </div>
      )}

      {coverKeypad && lockedTable && (
        <div className="fixed inset-0 z-50 grid place-items-center bg-black/40 p-4" role="dialog" aria-label="Order details">
          <div className="w-full max-w-sm rounded-xl p-4" style={{ background: "var(--color-surface)" }}>
            <div className="mb-3 text-center text-sm font-bold">Order Details (Table {lockedTable.number})</div>
            <div className="mb-2 flex items-center gap-2">
              <span className="text-xs font-semibold">Cover</span>
              <div className="field flex h-11 flex-1 items-center justify-center text-lg font-bold">{keypadText || "0"}</div>
            </div>
            <div className="grid grid-cols-3 gap-2">
              {["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "00"].map((k) => (
                <button
                  key={k}
                  type="button"
                  className="h-12 rounded-lg border text-lg font-semibold"
                  style={{ borderColor: "var(--color-line)" }}
                  onClick={() => setKeypadText((t) => (t + k).replace(/^0+/, "").slice(0, 2))}
                >
                  {k}
                </button>
              ))}
              <button type="button" className="h-12 rounded-lg border text-sm font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setKeypadText((t) => t.slice(0, -1))}>
                ⌫
              </button>
            </div>
            <label className="mt-3 flex items-center justify-between gap-2 rounded-lg border px-3 py-2 text-sm" style={{ borderColor: "var(--color-line)" }}>
              <span className="font-semibold">NC KOT <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(no charge)</span></span>
              <input type="checkbox" className="h-5 w-5" checked={ncKot} onChange={(e) => setNcKot(e.target.checked)} />
            </label>
            {ncKot && (
              <input
                className="field mt-2 h-10 w-full text-sm"
                placeholder="Reason for the free order, e.g. guest name"
                aria-label="Reason for the no-charge order"
                maxLength={200}
                value={ncReason}
                onChange={(e) => setNcReason(e.target.value)}
              />
            )}
            {ncKot && <NcChargeSelect value={ncCharge} onChange={setNcCharge} onCount={setNcTargets} />}
            <div className="mt-3 flex justify-end gap-2">
              <button type="button" className="btn border px-4 text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => router.push("/pos")}>
                Back
              </button>
              <button
                type="button"
                className="btn btn-primary px-6 text-sm"
                disabled={!keypadText || Number(keypadText) < 1 || (ncKot && (ncReason.trim().length < 3 || (ncTargets > 0 && !ncCharge)))}
                onClick={() => {
                  setCovers(keypadText);
                  setCoverKeypad(false);
                }}
              >
                Next →
              </button>
            </div>
          </div>
        </div>
      )}

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

      {pricing && (
        <OpenPricePicker
          item={pricing}
          currency={currency}
          onCancel={() => setPricing(null)}
          onDone={(price) => {
            const item = pricing;
            setPricing(null);
            priceChosen(item, price);
          }}
        />
      )}

      {weighing && (
        <WeightPicker
          item={weighing.item}
          currency={currency}
          initialKg={weighing.kg}
          onCancel={() => setWeighing(null)}
          onDone={(kg) => {
            addWeighed(weighing.item, kg, weighing.key);
            setWeighing(null);
          }}
        />
      )}

      {sizing && (
        <SizePicker
          item={sizing}
          currency={currency}
          inCart={qtyInCart}
          onCancel={() => setSizing(null)}
          onPick={(id) => {
            setSizing(null);
            const size = menu.find((x) => x.id === id);
            if (size) tapItem(size);
          }}
        />
      )}

      {picking && (
        <OptionPicker
          item={pickPrice != null ? { ...picking, price: pickPrice } : picking}
          currency={currency}
          onCancel={() => setPicking(null)}
          onAdd={(opts) => {
            addLine(picking, opts, pickPrice ?? undefined);
            setPicking(null);
            setPickPrice(null);
          }}
        />
      )}
    </div>
  );
}

/** The price of an open-priced dish, typed at the till: more than zero, two decimals at most. The database checks the right again. */
export function OpenPricePicker({
  item,
  currency,
  onCancel,
  onDone,
}: {
  item: MenuItem;
  currency: string;
  onCancel: () => void;
  onDone: (price: number) => void;
}) {
  const [text, setText] = useState("");
  const problem = text.trim() === "" ? "" : openPriceError(text);
  const ok = text.trim() !== "" && !problem;
  return (
    <div className="fixed inset-0 z-50 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="card w-full max-w-sm p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label={`Price of ${item.name}`}>
        <h3 className="text-lg font-bold">{item.name}</h3>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          Open price: type the price for one ({currency}).
        </p>
        <label className="mt-4 block text-sm font-semibold">
          Price
          <input
            className="field mt-1.5 text-lg"
            inputMode="decimal"
            autoFocus
            value={text}
            onChange={(e) => setText(e.target.value.replace(/[^0-9.]/g, "").slice(0, 11))}
            onKeyDown={(e) => {
              if (e.key === "Enter" && ok) onDone(openPriceValue(text));
              if (e.key === "Escape") onCancel();
            }}
            placeholder="0.00"
          />
        </label>
        <p className="mt-2 min-h-5 text-sm font-semibold" style={{ color: problem ? "var(--color-bad)" : undefined }} role={problem ? "alert" : undefined}>
          {problem ? problem : ok ? money(openPriceValue(text), currency) : " "}
        </p>
        <div className="mt-3 flex gap-2">
          <button className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onCancel}>
            Cancel
          </button>
          <button className="btn btn-primary" style={{ flex: 1 }} disabled={!ok} onClick={() => onDone(openPriceValue(text))}>
            Add
          </button>
        </div>
      </div>
    </div>
  );
}

/** The weight of a dish sold by weight: type grams or kg, or tap a common weight. */
export function WeightPicker({
  item,
  currency,
  initialKg,
  onCancel,
  onDone,
}: {
  item: MenuItem;
  currency: string;
  initialKg?: number;
  onCancel: () => void;
  onDone: (kg: number) => void;
}) {
  const [grams, setGrams] = useState(initialKg ? String(Math.round(initialKg * 1000)) : "");
  const kg = Number(grams) / 1000;
  const ok = Number.isFinite(kg) && kg >= 0.005 && kg <= 999;
  return (
    <div className="fixed inset-0 z-50 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="card w-full max-w-sm p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label={`Weight of ${item.name}`}>
        <h3 className="text-lg font-bold">{item.name}</h3>
        <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
          {money(item.price, currency)} per kg
        </p>
        <label className="mt-4 block text-sm font-semibold">
          Weight in grams
          <input
            className="field mt-1.5 text-lg"
            inputMode="numeric"
            autoFocus
            value={grams}
            onChange={(e) => setGrams(e.target.value.replace(/[^0-9]/g, "").slice(0, 6))}
            onKeyDown={(e) => e.key === "Enter" && ok && onDone(kg)}
            placeholder="350"
          />
        </label>
        <div className="mt-2 grid grid-cols-4 gap-1.5">
          {[100, 250, 500, 1000].map((g) => (
            <button key={g} className="rounded-lg border py-2 text-sm font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setGrams(String(g))}>
              {g >= 1000 ? `${g / 1000} kg` : `${g} g`}
            </button>
          ))}
        </div>
        <p className="mt-3 text-sm font-semibold">{ok ? `${kg.toFixed(3)} kg = ${money(Math.round(item.price * kg * 100) / 100, currency)}` : " "}</p>
        <div className="mt-4 flex gap-2">
          <button className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onCancel}>
            Cancel
          </button>
          <button className="btn btn-primary" style={{ flex: 1 }} disabled={!ok} onClick={() => onDone(kg)}>
            {initialKg ? "Change weight" : "Add"}
          </button>
        </div>
      </div>
    </div>
  );
}

/** Which size of a dish: one tap adds it (or opens its options). */
export function SizePicker({
  item,
  currency,
  inCart,
  onCancel,
  onPick,
}: {
  item: MenuItem;
  currency: string;
  inCart: (id: string) => number;
  onCancel: () => void;
  onPick: (id: string) => void;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onCancel();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onCancel]);
  return (
    <div
      className="fixed inset-0 z-50 grid place-items-center p-4"
      style={{ background: "rgba(10,8,20,.55)" }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onCancel();
      }}
    >
      <div className="card w-full max-w-md p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label={`Size of ${item.name}`}>
        <h3 className="text-lg font-bold">{item.name}</h3>
        <p className="mt-0.5 text-sm" style={{ color: "var(--color-ink-3)" }}>
          Choose a size
        </p>
        <div className="mt-4 grid grid-cols-2 gap-2">
          {(item.variants ?? []).map((v, i) => {
            const n = inCart(v.id);
            return (
              <button
                key={v.id}
                autoFocus={i === 0}
                onClick={() => onPick(v.id)}
                className="tap relative flex min-h-16 flex-col items-start justify-center rounded-xl border px-3 py-2.5 text-left"
                style={{ borderColor: n ? "var(--color-brand)" : "var(--color-line)" }}
              >
                <span className="text-sm font-semibold">{v.name}</span>
                <span className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                  {money(v.price, currency)}
                </span>
                {n > 0 && (
                  <span className="absolute right-2 top-2 grid h-5 min-w-5 place-items-center rounded-full px-1 text-[11px] font-bold text-white" style={{ background: "var(--color-brand)" }}>
                    {n}
                  </span>
                )}
              </button>
            );
          })}
        </div>
        <div className="mt-4 flex justify-end">
          <button className="btn" onClick={onCancel}>
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}

export function OptionPicker({
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
        <div className="mt-4 max-h-[calc(60vh/var(--z))] space-y-4 overflow-y-auto">
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
function SavedBox({ text, slow, quiet = false, onOpen, onNext }: { text: string; slow: boolean; quiet?: boolean; onOpen: () => void; onNext?: () => void }) {
  // quiet (a KOT on the single order screen): no message while the ticket prints; it only appears if this takes too long.
  if (quiet && !slow) return null;
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

/** One-tap buttons for the outlet's best sellers (only dishes on sale now; a sold-out or hidden dish is left out). */
function TopSellers({ ids, menu, onTap }: { ids: string[]; menu: MenuItem[]; onTap: (item: MenuItem) => void }) {
  const items = ids.map((id) => menu.find((x) => x.id === id && !x.variantOf)).filter((x): x is MenuItem => !!x);
  if (items.length === 0) return null;
  return (
    <section aria-label="Top sellers" className="mb-4">
      <h2 className="mb-2 text-xs font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
        Top sellers
      </h2>
      <div className="flex flex-wrap gap-2">
        {items.map((item) => (
          <button
            key={item.id}
            type="button"
            onClick={() => onTap(item)}
            className="tap rounded-full border px-3 py-2 text-sm font-semibold"
            style={{ borderColor: "var(--color-line)", background: "var(--color-surface, transparent)" }}
          >
            {item.short_name || item.name}
          </button>
        ))}
      </div>
    </section>
  );
}

/** One button on the Winsar-style bar at the foot of the order screen: small, solid colour, white letters. */
function WinBtn({ children, tone, onClick, disabled = false, title }: { children: React.ReactNode; tone: string; onClick: () => void; disabled?: boolean; title?: string }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      title={title}
      className="min-h-11 min-w-[72px] shrink-0 rounded-lg px-3.5 text-sm font-bold text-white shadow-sm disabled:opacity-40"
      style={{ background: tone }}
    >
      {children}
    </button>
  );
}
