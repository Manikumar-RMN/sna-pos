"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { placeOrder, type PlaceOrderInput } from "./actions";

type MenuItem = {
  id: string;
  name: string;
  short_name: string | null;
  price: number;
  category_id: string;
  category_name: string;
  category_order: number | null;
  tax_rate: number | null;
  is_veg: boolean | null;
};

type PaymentMethod = {
  id: string;
  name: string;
  kind: string;
  affects_cash_drawer: boolean;
};

type CartLine = { item: MenuItem; qty: number };

function money(n: number, currency: string) {
  try {
    return new Intl.NumberFormat("en-IN", { style: "currency", currency }).format(n);
  } catch {
    return `${currency} ${n.toFixed(2)}`;
  }
}

function applyRounding(x: number, mode: string) {
  switch (mode) {
    case "nearest_1":
      return Math.round(x);
    case "nearest_0_05":
      return Math.round(x / 0.05) * 0.05;
    case "nearest_0_10":
      return Math.round(x / 0.1) * 0.1;
    default:
      return Math.round(x * 100) / 100;
  }
}

export function PosTerminal({
  currency,
  roundingMode,
  canDiscount,
  menu,
  paymentMethods,
}: {
  currency: string;
  roundingMode: string;
  canDiscount: boolean;
  menu: MenuItem[];
  paymentMethods: PaymentMethod[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [cart, setCart] = useState<Record<string, CartLine>>({});
  const [search, setSearch] = useState("");
  const [orderType, setOrderType] = useState<"dine_in" | "takeaway">("dine_in");
  const [methodId, setMethodId] = useState<string>(paymentMethods[0]?.id ?? "");
  const [tendered, setTendered] = useState<string>("");
  const [discount, setDiscount] = useState<string>("");
  const [discountReason, setDiscountReason] = useState<string>("");
  const [error, setError] = useState<string | null>(null);

  const categories = useMemo(() => {
    const q = search.trim().toLowerCase();
    const filtered = q
      ? menu.filter(
          (m) =>
            m.name.toLowerCase().includes(q) ||
            (m.short_name ?? "").toLowerCase().includes(q),
        )
      : menu;
    const groups: { id: string; name: string; items: MenuItem[] }[] = [];
    for (const m of filtered) {
      let g = groups.find((x) => x.id === m.category_id);
      if (!g) {
        g = { id: m.category_id, name: m.category_name, items: [] };
        groups.push(g);
      }
      g.items.push(m);
    }
    return groups;
  }, [menu, search]);

  const lines = Object.values(cart);
  const selectedMethod = paymentMethods.find((m) => m.id === methodId);
  const isCash = selectedMethod?.kind === "cash";

  const totals = useMemo(() => {
    let subtotal = 0;
    for (const { item, qty } of lines) subtotal += Math.round(Number(item.price) * qty * 100) / 100;
    const discountWanted = Math.max(0, Number(discount) || 0);
    const discountAmt = Math.min(discountWanted, subtotal);
    let taxTotal = 0;
    for (const { item, qty } of lines) {
      const lineSub = Math.round(Number(item.price) * qty * 100) / 100;
      const lineDisc = subtotal > 0 ? Math.round(discountAmt * (lineSub / subtotal) * 100) / 100 : 0;
      const net = lineSub - lineDisc;
      const rate = Number(item.tax_rate) || 0;
      taxTotal += Math.round((net * rate) / 100 * 100) / 100;
    }
    taxTotal = Math.round(taxTotal * 100) / 100;
    const beforeRound = subtotal - discountAmt + taxTotal;
    const grand = applyRounding(beforeRound, roundingMode);
    const rounding = Math.round((grand - beforeRound) * 100) / 100;
    return { subtotal, discountAmt, taxTotal, grand, rounding };
  }, [lines, discount, roundingMode]);

  const change =
    isCash && Number(tendered) > 0 ? Math.max(0, Number(tendered) - totals.grand) : 0;

  function add(item: MenuItem) {
    setError(null);
    setCart((c) => {
      const cur = c[item.id];
      return { ...c, [item.id]: { item, qty: (cur?.qty ?? 0) + 1 } };
    });
  }
  function step(id: string, delta: number) {
    setCart((c) => {
      const cur = c[id];
      if (!cur) return c;
      const qty = cur.qty + delta;
      if (qty <= 0) {
        const { [id]: _drop, ...rest } = c;
        return rest;
      }
      return { ...c, [id]: { ...cur, qty } };
    });
  }
  function clearAll() {
    setCart({});
    setDiscount("");
    setDiscountReason("");
    setTendered("");
    setError(null);
  }

  function charge() {
    setError(null);
    if (lines.length === 0) return setError("Add at least one item.");
    if (!methodId) return setError("Choose how the customer paid.");
    if (totals.discountAmt > 0 && !canDiscount)
      return setError("A manager must approve a discount.");
    if (isCash && tendered !== "" && Number(tendered) < totals.grand)
      return setError("Amount received is less than the total.");

    const input: PlaceOrderInput = {
      items: lines.map((l) => ({ product_id: l.item.id, qty: l.qty })),
      order_type: orderType,
      payment_method_id: methodId,
      tendered: isCash && tendered !== "" ? Number(tendered) : null,
      discount_amount: totals.discountAmt,
      discount_reason: totals.discountAmt > 0 ? discountReason.trim() || null : null,
    };

    startTransition(async () => {
      const res = await placeOrder(input);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      router.push(`/pos/receipt/${res.orderId}`);
    });
  }

  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_360px]">
      {/* Menu */}
      <div>
        <div className="mb-3 flex items-center gap-3">
          <h1 className="text-xl font-bold tracking-tight">Billing</h1>
          <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Tap an item to add it
          </span>
        </div>
        <input
          className="field mb-4"
          placeholder="Search the menu…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          autoComplete="off"
        />
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
                  const inCart = cart[item.id]?.qty ?? 0;
                  return (
                    <button
                      key={item.id}
                      onClick={() => add(item)}
                      className="tap card relative flex flex-col items-start justify-between gap-1 p-3 text-left transition active:scale-[0.98]"
                      style={{ borderColor: inCart ? "var(--color-brand)" : "var(--color-line)" }}
                    >
                      <span className="flex items-start gap-1.5 text-sm font-semibold leading-tight">
                        {item.is_veg != null && (
                          <span
                            className="mt-1 inline-block h-2.5 w-2.5 shrink-0 rounded-[3px] border"
                            style={{
                              borderColor: item.is_veg ? "var(--color-ok)" : "var(--color-bad)",
                              background: item.is_veg ? "var(--color-ok)" : "var(--color-bad)",
                            }}
                          />
                        )}
                        {item.name}
                      </span>
                      <span className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                        {money(Number(item.price), currency)}
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

      {/* Bill */}
      <div className="lg:sticky lg:top-4 lg:self-start">
        <div className="card flex max-h-[calc(100vh-2rem)] flex-col">
          <div className="flex items-center justify-between border-b px-4 py-3" style={{ borderColor: "var(--color-line)" }}>
            <div className="text-sm font-bold">Current bill</div>
            <div className="flex overflow-hidden rounded-lg border" style={{ borderColor: "var(--color-line)" }}>
              {(["dine_in", "takeaway"] as const).map((t) => (
                <button
                  key={t}
                  onClick={() => setOrderType(t)}
                  className="px-2.5 py-1.5 text-[11px] font-semibold"
                  style={{
                    background: orderType === t ? "var(--color-brand)" : "transparent",
                    color: orderType === t ? "#fff" : "var(--color-ink-2)",
                  }}
                >
                  {t === "dine_in" ? "Dine-in" : "Takeaway"}
                </button>
              ))}
            </div>
          </div>

          <div className="flex-1 overflow-y-auto px-4 py-2">
            {lines.length === 0 ? (
              <p className="py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                No items yet.
              </p>
            ) : (
              <ul className="divide-y" style={{ borderColor: "var(--color-line)" }}>
                {lines.map(({ item, qty }) => (
                  <li key={item.id} className="flex items-center gap-2 py-2">
                    <div className="min-w-0 flex-1">
                      <div className="truncate text-sm font-medium">{item.name}</div>
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {money(Number(item.price), currency)}
                      </div>
                    </div>
                    <div className="flex items-center gap-1.5">
                      <button
                        onClick={() => step(item.id, -1)}
                        className="grid h-7 w-7 place-items-center rounded-md border text-base leading-none"
                        style={{ borderColor: "var(--color-line)" }}
                        aria-label="one less"
                      >
                        −
                      </button>
                      <span className="w-5 text-center text-sm font-semibold">{qty}</span>
                      <button
                        onClick={() => step(item.id, 1)}
                        className="grid h-7 w-7 place-items-center rounded-md border text-base leading-none"
                        style={{ borderColor: "var(--color-line)" }}
                        aria-label="one more"
                      >
                        +
                      </button>
                    </div>
                    <div className="w-16 text-right text-sm font-semibold">
                      {money(Math.round(Number(item.price) * qty * 100) / 100, currency)}
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </div>

          <div className="border-t px-4 py-3" style={{ borderColor: "var(--color-line)" }}>
            {canDiscount && lines.length > 0 && (
              <div className="mb-3 space-y-2">
                <div className="flex items-center gap-2">
                  <label className="text-xs font-medium" style={{ color: "var(--color-ink-2)" }}>
                    Discount
                  </label>
                  <input
                    className="field h-9 flex-1 text-sm"
                    inputMode="decimal"
                    placeholder="0"
                    value={discount}
                    onChange={(e) => setDiscount(e.target.value)}
                  />
                </div>
                {totals.discountAmt > 0 && (
                  <input
                    className="field h-9 text-sm"
                    placeholder="Reason (optional)"
                    value={discountReason}
                    onChange={(e) => setDiscountReason(e.target.value)}
                  />
                )}
              </div>
            )}

            <dl className="space-y-1 text-sm">
              <div className="flex justify-between">
                <dt style={{ color: "var(--color-ink-3)" }}>Subtotal</dt>
                <dd>{money(totals.subtotal, currency)}</dd>
              </div>
              {totals.discountAmt > 0 && (
                <div className="flex justify-between" style={{ color: "var(--color-ok)" }}>
                  <dt>Discount</dt>
                  <dd>−{money(totals.discountAmt, currency)}</dd>
                </div>
              )}
              <div className="flex justify-between">
                <dt style={{ color: "var(--color-ink-3)" }}>Tax</dt>
                <dd>{money(totals.taxTotal, currency)}</dd>
              </div>
              {Math.abs(totals.rounding) >= 0.005 && (
                <div className="flex justify-between" style={{ color: "var(--color-ink-3)" }}>
                  <dt>Rounding</dt>
                  <dd>
                    {totals.rounding > 0 ? "+" : "−"}
                    {money(Math.abs(totals.rounding), currency)}
                  </dd>
                </div>
              )}
              <div className="flex justify-between border-t pt-1.5 text-base font-bold" style={{ borderColor: "var(--color-line)" }}>
                <dt>Total</dt>
                <dd>{money(totals.grand, currency)}</dd>
              </div>
            </dl>

            <div className="mt-3">
              <div className="mb-1.5 text-xs font-medium" style={{ color: "var(--color-ink-2)" }}>
                Payment
              </div>
              <div className="grid grid-cols-3 gap-1.5">
                {paymentMethods.map((m) => (
                  <button
                    key={m.id}
                    onClick={() => setMethodId(m.id)}
                    className="rounded-lg border px-2 py-2 text-xs font-semibold"
                    style={{
                      borderColor: methodId === m.id ? "var(--color-brand)" : "var(--color-line)",
                      background: methodId === m.id ? "var(--color-brand-soft)" : "transparent",
                      color: methodId === m.id ? "var(--color-brand-strong)" : "var(--color-ink-2)",
                    }}
                  >
                    {m.name}
                  </button>
                ))}
              </div>
              {isCash && (
                <div className="mt-2 flex items-center gap-2">
                  <input
                    className="field h-9 flex-1 text-sm"
                    inputMode="decimal"
                    placeholder="Cash received"
                    value={tendered}
                    onChange={(e) => setTendered(e.target.value)}
                  />
                  <div className="w-24 text-right text-sm">
                    <span style={{ color: "var(--color-ink-3)" }}>Change </span>
                    <span className="font-semibold">{money(change, currency)}</span>
                  </div>
                </div>
              )}
            </div>

            {error && (
              <p className="mt-3 rounded-lg px-3 py-2 text-xs" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
                {error}
              </p>
            )}

            <div className="mt-3 flex gap-2">
              <button
                onClick={clearAll}
                disabled={pending || lines.length === 0}
                className="btn border text-sm"
                style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}
              >
                Clear
              </button>
              <button
                onClick={charge}
                disabled={pending || lines.length === 0}
                className="btn btn-primary flex-1"
              >
                {pending ? "Saving…" : `Charge ${money(totals.grand, currency)}`}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
