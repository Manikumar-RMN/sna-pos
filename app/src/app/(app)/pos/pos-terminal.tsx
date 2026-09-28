"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money, roundCash } from "@/lib/format";
import { UpiQr } from "../upi-qr";
import { ApprovalPrompt, cleanMessage, neededRight } from "../approval";
import { addToBill, getOfflineSnapshot, placeOrder, quoteOrder, type PlaceOrderInput, type Quote, type Senior } from "./actions";
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
type Table = { id: string; number: string; busy: boolean; openBillId: string | null; openBillNumber: string | null };
type ChosenOption = { id: string; name: string; price: number };
type CartLine = { key: string; item: MenuItem; qty: number; options: ChosenOption[]; note: string; hold?: boolean };

/** One-tap kitchen notes; staff can also type their own. */
const QUICK_NOTES = ["No onion", "No garlic", "Less spicy", "Extra spicy", "Less oil", "Parcel"];
export type AddTo = { id: string; billNumber: string; table: string | null };

function lineKey(productId: string, options: ChosenOption[]) {
  return productId + "|" + options.map((o) => o.id).sort().join(",");
}
function unitPrice(l: { item: MenuItem; options: ChosenOption[] }) {
  return Math.round((l.item.price + l.options.reduce((s, o) => s + o.price, 0)) * 100) / 100;
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
  allowHold = false,
  customerDisplay = null,
  tableOrdersWaiting = 0,
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
  /** Professional: hold items for the next course. */
  allowHold?: boolean;
  /** Add-on: a second screen facing the guest shows the order and total. Value = restaurant name. */
  customerDisplay?: string | null;
  /** Add-on: orders sent by guests from the table QR, waiting for staff. */
  tableOrdersWaiting?: number;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [cart, setCart] = useState<Record<string, CartLine>>({});
  const [search, setSearch] = useState("");
  const [orderType, setOrderType] = useState<"dine_in" | "takeaway">("dine_in");
  const [tableId, setTableId] = useState<string | null>(null);
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

  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoting, setQuoting] = useState(false);
  const reqId = useRef(0);

  const m = (n: number) => money(n, currency);
  const lines = Object.values(cart);
  const isCash = paymentMethods.find((p) => p.id === methodId)?.kind === "cash";
  const askRef = !!paymentMethods.find((p) => p.id === methodId)?.ask_reference;
  const discountAmt = Math.max(0, Number(discount) || 0);
  const chosenTable = tables.find((t) => t.id === tableId) ?? null;

  const categories = useMemo(() => {
    const q = search.trim().toLowerCase();
    const filtered = q
      ? menu.filter((x) => x.name.toLowerCase().includes(q) || (x.short_name ?? "").toLowerCase().includes(q))
      : menu;
    const groups: { id: string; name: string; items: MenuItem[] }[] = [];
    for (const x of filtered) {
      let g = groups.find((y) => y.id === x.category_id);
      if (!g) {
        g = { id: x.category_id, name: x.category_name, items: [] };
        groups.push(g);
      }
      g.items.push(x);
    }
    return groups;
  }, [menu, search]);

  const qtyInCart = (productId: string) => lines.filter((l) => l.item.id === productId).reduce((s, l) => s + l.qty, 0);
  const itemsPayload = () =>
    lines.map((l) => ({ product_id: l.item.id, qty: l.qty, options: l.options.map((o) => o.id), note: l.note.trim() || undefined, hold: !!l.hold }));

  // Ask the database for the exact bill whenever the cart changes (new bills only).
  // Replies that arrive out of order are ignored.
  const cartKey = JSON.stringify([lines.map((l) => [l.key, l.qty]), discountAmt, scChoice, senior]);
  const [noteOpen, setNoteOpen] = useState<string | null>(null);
  const [approval, setApproval] = useState<null | { permission: string; retry: () => void }>(null);
  // Same id for every retry of this bill; a new one after it is saved.
  const [clientRef, setClientRef] = useState(() => crypto.randomUUID());
  // Offline billing: a copy of the menu and tax rules on this device.
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [offline, setOffline] = useState(false);
  const [offlineBill, setOfflineBill] = useState<OfflineBill | null>(null);

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

  function localQuote(): Quote | string {
    if (!snap) return "No internet, and this device has no offline copy of the menu yet. Open Billing once while online.";
    if (senior) return "The senior citizen / PWD discount needs the internet.";
    try {
      const c = offlineQuote(
        snap,
        lines.map((l) => ({ product_id: l.item.id, qty: l.qty, unit_price: unitPrice(l) })),
        snap.rights.discount ? discountAmt : 0,
        scChoice,
      );
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
      lines: Object.values(cart).map((l) => ({
        name: l.item.name,
        local: l.item.name_local ?? null,
        options: l.options.map((o) => o.name).join(", ") || null,
        qty: l.qty,
        amount: Math.round(unitPrice(l) * l.qty * 100) / 100,
      })),
      total: quote && Object.keys(cart).length ? quote.grand_total : null,
    });
    ch.close();
  }, [cart, quote, customerDisplay, currency]);

  const due = quote ? (isCash ? roundCash(quote.grand_total, quote.cash_rounding) : quote.grand_total) : 0;
  const cashRound = quote && isCash ? Math.round((due - quote.grand_total) * 100) / 100 : 0;
  const change = isCash && Number(tendered) > due ? Math.round((Number(tendered) - due) * 100) / 100 : 0;
  const addedTax = quote ? Math.round((quote.tax_total - quote.tax_included) * 100) / 100 : 0;
  const addSubtotal = Math.round(lines.reduce((s, l) => s + unitPrice(l) * l.qty, 0) * 100) / 100;

  function tapItem(item: MenuItem) {
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
    setDiscount("");
    setDiscountReason("");
    setTendered("");
    setReference("");
    setTableId(null);
    setScChoice(null);
    setSenior(null);
    setError(null);
  }

  function submitOffline(mode: "pay" | "unpaid" | "split") {
    if (!snap || !quote) return setError("No internet, and this device has no offline copy of the menu yet.");
    if (mode !== "pay") return setError("Without internet only paid bills can be made. Take the payment now.");
    if (!canPay) return setError("Without internet only the cashier can make bills here.");
    const method = paymentMethods.find((p) => p.id === methodId);
    if (!method) return setError("Choose how the customer paid.");
    const byId = new Map(snap.menu.map((m) => [m.id, m]));
    const missing = lines.find((l) => !byId.has(l.item.id));
    if (missing) return setError(`${missing.item.name} is not in this device's offline menu. Remove it or wait for the internet.`);
    const calc = offlineQuote(
      snap,
      lines.map((l) => ({ product_id: l.item.id, qty: l.qty, unit_price: unitPrice(l) })),
      snap.rights.discount ? discountAmt : 0,
      scChoice,
    );
    const dueNow = cashDue(snap, calc.grand_total, method.kind === "cash");
    if (method.kind === "cash" && tendered !== "" && Number(tendered) < dueNow) return setError("Amount received is less than the total.");
    const { seq, number } = takeNumber(snap);
    const bill: OfflineBill = {
      client_id: crypto.randomUUID(),
      device_key: snap.device_key,
      seq,
      fy: snap.series.fy,
      number,
      created_at: new Date().toISOString(),
      order_type: orderType,
      items: lines.map((l) => ({
        product_id: l.item.id,
        name: l.item.name,
        qty: l.qty,
        price: unitPrice(l),
        options: l.options.map((o) => o.id),
        options_text: l.options.map((o) => o.name).join(", ") || null,
        note: l.note.trim() || undefined,
        station: byId.get(l.item.id)?.station ?? "Kitchen",
      })),
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
    setOfflineBill(bill);
  }

  function submit(mode: "pay" | "unpaid" | "split") {
    setError(null);
    if (lines.length === 0) return setError("Add at least one item.");
    if (!quote || quoting) return setError("Please wait a moment — the total is being checked.");
    if (offline) return submitOffline(mode);
    const payNow = mode === "pay";
    if (payNow && !methodId) return setError("Choose how the customer paid.");
    if (payNow && isCash && tendered !== "" && Number(tendered) < due) return setError("Amount received is less than the total.");

    const input: PlaceOrderInput = {
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
      client_ref: clientRef,
    };
    startTransition(async () => {
      let res: Awaited<ReturnType<typeof placeOrder>>;
      try {
        res = await placeOrder(input);
      } catch {
        // The internet dropped while saving. Nothing reached the server's reply, so the same
        // request id makes a later retry safe; meanwhile the bill can be made offline.
        setOffline(true);
        return setError(
          "The internet dropped while saving, so this bill may already be saved. Check Bills when the internet is back. To bill offline now, press the button again.",
        );
      }
      if (!res.ok) {
        const need = neededRight(res.error);
        if (need) setApproval({ permission: need, retry: () => submit(mode) });
        return setError(cleanMessage(res.error));
      }
      setClientRef(crypto.randomUUID());
      if (mode === "split") router.push(`/bills/${res.orderId}?pay=split`);
      else router.push(`/pos/receipt/${res.orderId}${mode === "pay" ? "?print=1" : ""}`);
    });
  }

  function submitAdd() {
    if (!addTo) return;
    setError(null);
    if (offline) return setError("Adding to an open bill needs the internet.");
    if (lines.length === 0) return setError("Add at least one item.");
    startTransition(async () => {
      const res = await addToBill(addTo.id, itemsPayload());
      if (!res.ok) return setError(res.error);
      router.push(`/bills/${addTo.id}`);
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
        <input className="field mb-4" placeholder="Search the menu…" value={search} onChange={(e) => setSearch(e.target.value)} autoComplete="off" />
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
                {(["dine_in", "takeaway"] as const).map((t) => (
                  <button
                    key={t}
                    onClick={() => setOrderType(t)}
                    className="px-2.5 py-1.5 text-[11px] font-semibold"
                    style={{ background: orderType === t ? "var(--color-brand)" : "transparent", color: orderType === t ? "#fff" : "var(--color-ink-2)" }}
                  >
                    <Dual text={t === "dine_in" ? "Dine-in" : "Takeaway"} />
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
                <Chip label="None" active={tableId === null} onClick={() => setTableId(null)} />
                {tables.map((t) => (
                  <Chip key={t.id} label={`T${t.number}`} busy={t.busy} active={tableId === t.id} onClick={() => setTableId(t.id)} />
                ))}
              </div>
              {chosenTable?.openBillId && (
                <div className="mt-2 flex items-center justify-between gap-2 rounded-md px-2.5 py-1.5 text-xs" style={{ background: "var(--color-warn-soft)" }}>
                  <span>
                    Table {chosenTable.number} already has bill {chosenTable.openBillNumber}.
                  </span>
                  <button
                    className="shrink-0 font-semibold underline"
                    style={{ color: "var(--color-brand-strong)" }}
                    onClick={() => router.push(`/pos?add=${chosenTable.openBillId}`)}
                  >
                    Add to that bill
                  </button>
                </div>
              )}
            </div>
          )}

          <div className="flex-1 overflow-y-auto px-4 py-2">
            {lines.length === 0 ? (
              <p className="py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                No items yet.
              </p>
            ) : (
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
              {error && <ErrorBox text={error} />}
              <div className="mt-3 flex gap-2">
                <button onClick={() => router.push(`/bills/${addTo.id}`)} disabled={pending} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                  Back to bill
                </button>
                <button onClick={submitAdd} disabled={pending || lines.length === 0} className="btn btn-primary flex-1">
                  {pending ? "Adding…" : `Add ${lines.reduce((s, l) => s + l.qty, 0) || ""} to bill`}
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

              {error && <ErrorBox text={error} />}

              <div className="mt-3 flex gap-2">
                <button onClick={clearAll} disabled={pending || lines.length === 0} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                  Clear
                </button>
                {canPay ? (
                  <>
                    <button onClick={() => submit("unpaid")} disabled={pending || quoting || !quote} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                      Save unpaid
                    </button>
                    <button onClick={() => submit("pay")} disabled={pending || quoting || !quote} className="btn btn-pay flex-1 text-base">
                      {pending ? "Saving…" : <Dual text="Charge" />}
                      {!pending && quote ? ` ${m(due)}` : ""}
                    </button>
                  </>
                ) : (
                  <button onClick={() => submit("unpaid")} disabled={pending || quoting || !quote} className="btn btn-primary flex-1 text-base">
                    {pending ? "Saving…" : <Dual text="Send to kitchen" />}
                  </button>
                )}
              </div>
              {canPay ? (
                <button
                  onClick={() => submit("split")}
                  disabled={pending || quoting || !quote}
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
