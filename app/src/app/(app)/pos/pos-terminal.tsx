"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money, roundCash } from "@/lib/format";
import { placeOrder, quoteOrder, type PlaceOrderInput, type Quote, type Senior } from "./actions";

type MenuItem = {
  id: string;
  name: string;
  short_name: string | null;
  price: number;
  category_id: string;
  category_name: string;
  is_veg: boolean | null;
};
type PaymentMethod = { id: string; name: string; kind: string };
type Table = { id: string; number: string; busy: boolean };
type CartLine = { item: MenuItem; qty: number };

export function PosTerminal({
  currency,
  canDiscount,
  showSenior,
  pricesIncludeTax,
  taxName,
  menu,
  paymentMethods,
  tables,
}: {
  currency: string;
  canDiscount: boolean;
  /** Philippines: senior citizen / PWD discount. */
  showSenior: boolean;
  pricesIncludeTax: boolean;
  taxName: string;
  menu: MenuItem[];
  paymentMethods: PaymentMethod[];
  tables: Table[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [cart, setCart] = useState<Record<string, CartLine>>({});
  const [search, setSearch] = useState("");
  const [orderType, setOrderType] = useState<"dine_in" | "takeaway">("dine_in");
  const [tableId, setTableId] = useState<string | null>(null);
  const [methodId, setMethodId] = useState<string>(paymentMethods[0]?.id ?? "");
  const [tendered, setTendered] = useState("");
  const [discount, setDiscount] = useState("");
  const [discountReason, setDiscountReason] = useState("");
  const [scChoice, setScChoice] = useState<boolean | null>(null);
  const [senior, setSenior] = useState<Senior | null>(null);
  const [seniorOpen, setSeniorOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoting, setQuoting] = useState(false);
  const reqId = useRef(0);

  const m = (n: number) => money(n, currency);
  const lines = Object.values(cart);
  const isCash = paymentMethods.find((p) => p.id === methodId)?.kind === "cash";
  const discountAmt = Math.max(0, Number(discount) || 0);

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

  // Ask the database for the exact bill whenever the cart changes. Replies that
  // arrive out of order are ignored.
  const cartKey = JSON.stringify([lines.map((l) => [l.item.id, l.qty]), discountAmt, scChoice, senior]);
  useEffect(() => {
    if (lines.length === 0) {
      setQuote(null);
      setQuoting(false);
      return;
    }
    const id = ++reqId.current;
    setQuoting(true);
    const t = setTimeout(async () => {
      const res = await quoteOrder({
        items: lines.map((l) => ({ product_id: l.item.id, qty: l.qty })),
        discount_amount: discountAmt,
        service_charge: scChoice,
        senior,
      });
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
  }, [cartKey]);

  const due = quote ? (isCash ? roundCash(quote.grand_total, quote.cash_rounding) : quote.grand_total) : 0;
  const cashRound = quote && isCash ? Math.round((due - quote.grand_total) * 100) / 100 : 0;
  const change = isCash && Number(tendered) > due ? Math.round((Number(tendered) - due) * 100) / 100 : 0;
  const addedTax = quote ? Math.round((quote.tax_total - quote.tax_included) * 100) / 100 : 0;

  function add(item: MenuItem) {
    setError(null);
    setCart((c) => ({ ...c, [item.id]: { item, qty: (c[item.id]?.qty ?? 0) + 1 } }));
  }
  function step(id: string, delta: number) {
    setCart((c) => {
      const cur = c[id];
      if (!cur) return c;
      const qty = cur.qty + delta;
      if (qty <= 0) {
        const rest = { ...c };
        delete rest[id];
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
    setTableId(null);
    setScChoice(null);
    setSenior(null);
    setError(null);
  }

  function submit(payNow: boolean) {
    setError(null);
    if (lines.length === 0) return setError("Add at least one item.");
    if (!quote || quoting) return setError("Please wait a moment — the total is being checked.");
    if (payNow && !methodId) return setError("Choose how the customer paid.");
    if (payNow && isCash && tendered !== "" && Number(tendered) < due) return setError("Amount received is less than the total.");

    const input: PlaceOrderInput = {
      items: lines.map((l) => ({ product_id: l.item.id, qty: l.qty })),
      discount_amount: senior ? 0 : discountAmt,
      service_charge: scChoice,
      senior,
      order_type: orderType,
      table_id: orderType === "dine_in" ? tableId : null,
      payment_method_id: payNow ? methodId : null,
      tendered: payNow && isCash && tendered !== "" ? Number(tendered) : null,
      discount_reason: discountAmt > 0 ? discountReason.trim() || null : null,
    };
    startTransition(async () => {
      const res = await placeOrder(input);
      if (!res.ok) return setError(res.error);
      router.push(`/pos/receipt/${res.orderId}`);
    });
  }

  return (
    <div className="grid gap-4 lg:grid-cols-[1fr_360px]">
      <div>
        <div className="mb-3 flex flex-wrap items-center gap-x-3">
          <h1 className="text-xl font-bold tracking-tight">Billing</h1>
          <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Tap an item to add it · prices {pricesIncludeTax ? `include ${taxName}` : `before ${taxName}`}
          </span>
        </div>
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
                            className="mt-1 inline-block h-2.5 w-2.5 shrink-0 rounded-[3px]"
                            style={{ background: item.is_veg ? "var(--color-ok)" : "var(--color-bad)" }}
                          />
                        )}
                        {item.name}
                      </span>
                      <span className="text-sm" style={{ color: "var(--color-ink-2)" }}>
                        {m(item.price)}
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
                  style={{ background: orderType === t ? "var(--color-brand)" : "transparent", color: orderType === t ? "#fff" : "var(--color-ink-2)" }}
                >
                  {t === "dine_in" ? "Dine-in" : "Takeaway"}
                </button>
              ))}
            </div>
          </div>

          {orderType === "dine_in" && tables.length > 0 && (
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
            </div>
          )}

          <div className="flex-1 overflow-y-auto px-4 py-2">
            {lines.length === 0 ? (
              <p className="py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                No items yet.
              </p>
            ) : (
              <ul>
                {lines.map(({ item, qty }) => (
                  <li key={item.id} className="flex items-center gap-2 border-b py-2 last:border-0" style={{ borderColor: "var(--color-line)" }}>
                    <div className="min-w-0 flex-1">
                      <div className="truncate text-sm font-medium">{item.name}</div>
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {m(item.price)}
                      </div>
                    </div>
                    <div className="flex items-center gap-1.5">
                      <button onClick={() => step(item.id, -1)} className="grid h-8 w-8 place-items-center rounded-md border text-base" style={{ borderColor: "var(--color-line)" }} aria-label={`One less ${item.name}`}>
                        −
                      </button>
                      <span className="w-5 text-center text-sm font-semibold">{qty}</span>
                      <button onClick={() => step(item.id, 1)} className="grid h-8 w-8 place-items-center rounded-md border text-base" style={{ borderColor: "var(--color-line)" }} aria-label={`One more ${item.name}`}>
                        +
                      </button>
                    </div>
                    <div className="w-20 text-right text-sm font-semibold">{m(Math.round(item.price * qty * 100) / 100)}</div>
                  </li>
                ))}
              </ul>
            )}
          </div>

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
                {canDiscount && !senior && (
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

            {error && (
              <p className="mt-3 rounded-lg px-3 py-2 text-xs" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
                {error}
              </p>
            )}

            <div className="mt-3 flex gap-2">
              <button onClick={clearAll} disabled={pending || lines.length === 0} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                Clear
              </button>
              <button onClick={() => submit(false)} disabled={pending || quoting || !quote} className="btn border px-3 text-sm" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
                Save unpaid
              </button>
              <button onClick={() => submit(true)} disabled={pending || quoting || !quote} className="btn btn-primary flex-1">
                {pending ? "Saving…" : quote ? `Charge ${m(due)}` : "Charge"}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
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
