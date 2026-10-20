"use client";

import { useEffect, useMemo, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { DishName } from "../lang";
import { addToBill, placeOrder, type CartItem } from "../pos/actions";
import { KotSheet } from "./kot-sheet";
import { ReadyAlerts } from "./ready-alerts";
import { OptionPicker, SizePicker, WeightPicker, qtyText, type ChosenOption, type MenuItem } from "../pos/pos-terminal";

export type CaptainTable = {
  id: string;
  number: string;
  seats: number | null;
  bills: { id: string; billNumber: string; total: number; since: string; covers: number | null }[];
};
type Line = { key: string; item: MenuItem; options: ChosenOption[]; qty: number; note: string };
type Target = { table: CaptainTable; billId: string | null; billNumber: string | null; covers: number | null };

const minutesSince = (iso: string) => Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
const newRef = () => (typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : undefined);

export function Captain({
  currency,
  tables,
  menu,
  categoryParents,
}: {
  currency: string;
  tables: CaptainTable[];
  menu: MenuItem[];
  categoryParents: Record<string, { id: string; name: string }>;
}) {
  const router = useRouter();
  const [target, setTarget] = useState<Target | null>(null);
  const [asking, setAsking] = useState<CaptainTable | null>(null); // free table: how many guests / which bill
  const [done, setDone] = useState<string | null>(null);
  const m = (n: number) => money(n, currency);

  // The floor changes as other staff work: refresh the tables every 20 seconds while they are shown.
  useEffect(() => {
    if (target) return;
    const t = setInterval(() => router.refresh(), 20000);
    return () => clearInterval(t);
  }, [target, router]);

  if (target) {
    return (
      <OrderView
        target={target}
        menu={menu}
        currency={currency}
        categoryParents={categoryParents}
        onBack={() => setTarget(null)}
        onSent={(text) => {
          setTarget(null);
          setDone(text);
          router.refresh();
        }}
      />
    );
  }

  const busy = tables.filter((t) => t.bills.length).length;
  return (
    <div className="mx-auto max-w-3xl">
      <div className="mb-3 flex items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold tracking-tight">Captain</h1>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Tap a table to take its order. {busy} of {tables.length} tables busy.
          </p>
        </div>
        <Link href="/kitchen" className="text-xs font-semibold" style={{ color: "var(--color-brand)" }}>
          Kitchen →
        </Link>
      </div>
      <ReadyAlerts />
      {done && (
        <div role="status" className="mb-3 rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}>
          {done}
        </div>
      )}
      {tables.length === 0 ? (
        <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          No tables yet. An owner or manager can add them in Settings → Tables.
        </div>
      ) : (
        <div className="grid grid-cols-3 gap-2 sm:grid-cols-4 md:grid-cols-5">
          {tables.map((t) => {
            const total = t.bills.reduce((s, b) => s + b.total, 0);
            const oldest = t.bills[0];
            const isBusy = t.bills.length > 0;
            return (
              <button
                key={t.id}
                onClick={() => {
                  setDone(null);
                  if (t.bills.length === 1) setTarget({ table: t, billId: t.bills[0].id, billNumber: t.bills[0].billNumber, covers: t.bills[0].covers });
                  else setAsking(t);
                }}
                className="tap card flex min-h-24 flex-col items-start justify-between p-3 text-left"
                style={{ borderColor: isBusy ? "var(--color-brand)" : "var(--color-line)", background: isBusy ? "var(--color-brand-soft)" : undefined }}
              >
                <span className="text-lg font-bold">{t.number}</span>
                {isBusy ? (
                  <span className="text-[11px] leading-tight" style={{ color: "var(--color-ink-2)" }}>
                    {m(total)}
                    <br />
                    {minutesSince(oldest.since)} min{oldest.covers ? ` · ${oldest.covers} guests` : ""}
                    {t.bills.length > 1 ? ` · ${t.bills.length} bills` : ""}
                  </span>
                ) : (
                  <span className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                    Free{t.seats ? ` · ${t.seats} seats` : ""}
                  </span>
                )}
              </button>
            );
          })}
        </div>
      )}
      {asking && (
        <StartSheet
          table={asking}
          currency={currency}
          onCancel={() => setAsking(null)}
          onPick={(t) => {
            setAsking(null);
            setTarget(t);
          }}
        />
      )}
    </div>
  );
}

/** A free table: how many guests? A table with several bills: which bill, or a new one? */
function StartSheet({ table, currency, onCancel, onPick }: { table: CaptainTable; currency: string; onCancel: () => void; onPick: (t: Target) => void }) {
  const [covers, setCovers] = useState<number | null>(null);
  return (
    <div className="fixed inset-0 z-50 grid items-end p-0 sm:place-items-center sm:p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onCancel()}>
      <div className="card w-full max-w-md rounded-b-none p-5 sm:rounded-b-2xl" style={{ background: "var(--color-surface)" }} role="dialog" aria-label={`Table ${table.number}`}>
        <h3 className="text-lg font-bold">Table {table.number}</h3>
        {table.bills.length > 0 && (
          <div className="mt-3 space-y-2">
            {table.bills.map((b) => (
              <button
                key={b.id}
                className="tap flex w-full items-center justify-between rounded-xl border px-3 py-3 text-left text-sm"
                style={{ borderColor: "var(--color-line)" }}
                onClick={() => onPick({ table, billId: b.id, billNumber: b.billNumber, covers: b.covers })}
              >
                <span className="font-semibold">Add to bill {b.billNumber}</span>
                <span style={{ color: "var(--color-ink-2)" }}>{money(b.total, currency)}</span>
              </button>
            ))}
            <div className="pt-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Or a separate bill for new guests:
            </div>
          </div>
        )}
        <div className="mt-3 text-sm font-semibold">How many guests?</div>
        <div className="mt-2 grid grid-cols-6 gap-1.5">
          {Array.from({ length: 12 }, (_, i) => i + 1).map((n) => (
            <button
              key={n}
              className="tap rounded-lg border py-2.5 text-sm font-semibold"
              style={{ borderColor: covers === n ? "var(--color-brand)" : "var(--color-line)", background: covers === n ? "var(--color-brand-soft)" : "transparent" }}
              onClick={() => setCovers(n)}
              aria-pressed={covers === n}
            >
              {n}
            </button>
          ))}
        </div>
        <div className="mt-4 flex gap-2">
          <button className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onCancel}>
            Cancel
          </button>
          <button className="btn btn-primary" style={{ flex: 1 }} onClick={() => onPick({ table, billId: null, billNumber: null, covers })}>
            {covers ? `Start order · ${covers} guests` : "Start order"}
          </button>
        </div>
      </div>
    </div>
  );
}

function OrderView({
  target,
  menu,
  currency,
  categoryParents,
  onBack,
  onSent,
}: {
  target: Target;
  menu: MenuItem[];
  currency: string;
  categoryParents: Record<string, { id: string; name: string }>;
  onBack: () => void;
  onSent: (text: string) => void;
}) {
  const [cart, setCart] = useState<Line[]>([]);
  const [search, setSearch] = useState("");
  const [tab, setTab] = useState<string | null>(null);
  const [sizing, setSizing] = useState<MenuItem | null>(null);
  const [picking, setPicking] = useState<MenuItem | null>(null);
  const [weighing, setWeighing] = useState<MenuItem | null>(null);
  const [showCart, setShowCart] = useState(false);
  const [showKots, setShowKots] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const ref = useRef<string | undefined>(newRef());
  const m = (n: number) => money(n, currency);

  const mains = useMemo(() => {
    const out: { id: string; name: string }[] = [];
    for (const x of menu) {
      if (x.variantOf) continue;
      const main = categoryParents[x.category_id] ?? { id: x.category_id, name: x.category_name };
      if (!out.some((c) => c.id === main.id)) out.push(main);
    }
    return out;
  }, [menu, categoryParents]);
  const activeTab = tab ?? mains[0]?.id ?? null;
  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return menu.filter((x) => {
      if (x.variantOf) return false;
      if (q) return x.name.toLowerCase().includes(q) || (x.short_name ?? "").toLowerCase().includes(q);
      return (categoryParents[x.category_id]?.id ?? x.category_id) === activeTab;
    });
  }, [menu, search, activeTab, categoryParents]);

  const count = cart.reduce((s, l) => s + (l.item.byWeight ? 1 : l.qty), 0);
  const total = cart.reduce((s, l) => s + l.qty * (l.item.price + l.options.reduce((a, o) => a + o.price, 0)), 0);
  const qtyOf = (item: MenuItem) =>
    cart.filter((l) => l.item.id === item.id || (item.variants ?? []).some((v) => v.id === l.item.id)).reduce((s, l) => s + (l.item.byWeight ? 1 : l.qty), 0);

  function add(item: MenuItem, options: ChosenOption[]) {
    const key = `${item.id}|${options.map((o) => o.id).sort().join(",")}`;
    setCart((c) => {
      const same = c.find((l) => l.key === key && !l.note);
      if (same) return c.map((l) => (l === same ? { ...l, qty: l.qty + 1 } : l));
      return [...c, { key, item, options, qty: 1, note: "" }];
    });
  }
  function tap(item: MenuItem) {
    setError(null);
    if (item.variants) {
      if (item.variants.length === 1) {
        const only = menu.find((x) => x.id === item.variants![0].id);
        if (only) tap(only);
      } else if (item.variants.length > 1) setSizing(item);
      return;
    }
    if (item.byWeight) return setWeighing(item);
    if (item.groups.length > 0) setPicking(item);
    else add(item, []);
  }
  function send() {
    if (!cart.length) return;
    setError(null);
    const items: CartItem[] = cart.map((l) => ({ product_id: l.item.id, qty: l.qty, options: l.options.map((o) => o.id), note: l.note.trim() || undefined }));
    start(async () => {
      if (target.billId) {
        const r = await addToBill(target.billId, items, ref.current);
        if (!r.ok) return setError(r.error);
        onSent(`Sent to the kitchen: ${count} item${count === 1 ? "" : "s"} for table ${target.table.number} (bill ${target.billNumber}).`);
      } else {
        const r = await placeOrder({
          items,
          discount_amount: 0,
          service_charge: null,
          senior: null,
          order_type: "dine_in",
          table_id: target.table.id,
          payment_method_id: null,
          tendered: null,
          discount_reason: null,
          client_ref: ref.current,
          guest: null,
          covers: target.covers,
        });
        if (!r.ok) return setError(r.error);
        onSent(`Sent to the kitchen: table ${target.table.number}, bill ${r.billNumber}.`);
      }
    });
  }

  return (
    <div className="mx-auto max-w-3xl pb-28">
      <div className="sticky top-0 z-10 -mx-4 mb-2 flex items-center gap-2 px-4 py-2" style={{ background: "var(--color-ground)" }}>
        <button className="btn" style={{ flex: "none", padding: "0 12px", minHeight: 40 }} onClick={onBack} aria-label="Back to tables">
          ←
        </button>
        <div className="min-w-0 flex-1">
          <div className="font-bold">Table {target.table.number}</div>
          <div className="truncate text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            {target.billId ? `Adding to bill ${target.billNumber}` : "New order"}
            {target.covers ? ` · ${target.covers} guests` : ""}
          </div>
        </div>
        {target.billId && (
          <button className="text-xs font-semibold" style={{ color: "var(--color-brand)" }} onClick={() => setShowKots(true)}>
            Sent KOTs
          </button>
        )}
        {target.billId && (
          <Link href={`/bills/${target.billId}`} className="text-xs font-semibold" style={{ color: "var(--color-brand)" }}>
            Bill →
          </Link>
        )}
      </div>
      <ReadyAlerts />
      {showKots && target.billId && <KotSheet orderId={target.billId} billNumber={target.billNumber} onClose={() => setShowKots(false)} onChanged={() => {}} />}

      <input className="field mb-2" placeholder="Search the menu…" value={search} onChange={(e) => setSearch(e.target.value)} autoComplete="off" />
      {!search.trim() && (
        <div className="-mx-4 mb-2 flex gap-1.5 overflow-x-auto px-4 pb-1">
          {mains.map((c) => (
            <button
              key={c.id}
              onClick={() => setTab(c.id)}
              aria-pressed={activeTab === c.id}
              className="shrink-0 rounded-full border px-3 py-1.5 text-xs font-semibold"
              style={{ borderColor: activeTab === c.id ? "var(--color-brand)" : "var(--color-line)", background: activeTab === c.id ? "var(--color-brand)" : "transparent", color: activeTab === c.id ? "#fff" : "var(--color-ink-2)" }}
            >
              {c.name}
            </button>
          ))}
        </div>
      )}

      <div className="card divide-y overflow-hidden" style={{ borderColor: "var(--color-line)" }}>
        {shown.length === 0 && (
          <p className="p-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Nothing here.
          </p>
        )}
        {shown.map((item) => {
          const n = qtyOf(item);
          return (
            <button key={item.id} onClick={() => tap(item)} className="tap flex w-full items-center gap-3 px-4 py-3 text-left" style={{ borderColor: "var(--color-line)" }}>
              {item.is_veg != null && (
                <span className="inline-block h-2.5 w-2.5 shrink-0 rounded-[3px]" style={{ background: item.is_veg ? "var(--color-ok)" : "var(--color-bad)" }} />
              )}
              <span className="min-w-0 flex-1">
                <span className="block text-sm font-semibold">
                  <DishName name={item.name} local={item.name_local} />
                </span>
                <span className="block text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {item.listPrice != null && <s className="mr-1">{m(item.listPrice)}</s>}
                  {item.variants?.length ? `from ${m(item.variants[0].price)} · ${item.variants.length} sizes` : m(item.price)}
                  {item.isCombo ? " · combo" : item.groups.length ? " · options" : ""}
                </span>
              </span>
              {n > 0 ? (
                <span className="grid h-7 min-w-7 place-items-center rounded-full px-2 text-xs font-bold text-white" style={{ background: "var(--color-brand)" }}>
                  {n}
                </span>
              ) : (
                <span className="text-xl font-bold" style={{ color: "var(--color-brand)" }} aria-hidden>
                  +
                </span>
              )}
            </button>
          );
        })}
      </div>

      {/* The order so far, always at the bottom of the phone screen. */}
      <div className="fixed inset-x-0 bottom-0 z-20 border-t p-3" style={{ background: "var(--color-surface)", borderColor: "var(--color-line)" }}>
        <div className="mx-auto max-w-3xl">
          {error && (
            <p className="mb-2 text-sm" role="alert" style={{ color: "var(--color-bad)" }}>
              {error}
            </p>
          )}
          <div className="flex gap-2">
            <button className="btn" style={{ flex: "none", padding: "0 14px" }} disabled={!count} onClick={() => setShowCart(true)}>
              {count} item{count === 1 ? "" : "s"} · {m(total)}
            </button>
            <button className="btn btn-primary" style={{ flex: 1 }} disabled={!count || pending} onClick={send}>
              {pending ? "Sending…" : "Send to kitchen"}
            </button>
          </div>
        </div>
      </div>

      {showCart && (
        <div className="fixed inset-0 z-50 grid items-end sm:place-items-center sm:p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && setShowCart(false)}>
          <div className="card max-h-[85vh] w-full max-w-md overflow-y-auto rounded-b-none p-5 sm:rounded-b-2xl" style={{ background: "var(--color-surface)" }} role="dialog" aria-label="This order">
            <h3 className="text-lg font-bold">This order</h3>
            <div className="mt-3 space-y-3">
              {cart.map((l, i) => (
                <div key={l.key + i} className="rounded-xl border p-2.5" style={{ borderColor: "var(--color-line)" }}>
                  <div className="flex items-center gap-2">
                    <div className="min-w-0 flex-1">
                      <div className="text-sm font-semibold">{l.item.name}</div>
                      {l.options.length > 0 && (
                        <div className="text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                          {l.options.map((o) => o.name).join(", ")}
                        </div>
                      )}
                    </div>
                    {l.item.byWeight ? (
                      <>
                        <span className="text-sm font-bold">{qtyText(l.qty, true)}</span>
                        <button className="btn" style={{ flex: "none", minHeight: 36, padding: "0 12px" }} onClick={() => setCart((c) => c.filter((x) => x !== l))} aria-label="Remove">
                          ✕
                        </button>
                      </>
                    ) : (
                      <>
                        <button className="btn" style={{ flex: "none", minHeight: 36, padding: "0 12px" }} onClick={() => setCart((c) => c.flatMap((x) => (x === l ? (x.qty > 1 ? [{ ...x, qty: x.qty - 1 }] : []) : [x])))} aria-label="One less">
                          −
                        </button>
                        <span className="w-6 text-center text-sm font-bold">{l.qty}</span>
                        <button className="btn" style={{ flex: "none", minHeight: 36, padding: "0 12px" }} onClick={() => setCart((c) => c.map((x) => (x === l ? { ...x, qty: x.qty + 1 } : x)))} aria-label="One more">
                          +
                        </button>
                      </>
                    )}
                  </div>
                  <input
                    className="field mt-2 h-9 text-xs"
                    placeholder="Note for the kitchen (no onion, less spicy)"
                    maxLength={200}
                    value={l.note}
                    onChange={(e) => setCart((c) => c.map((x) => (x === l ? { ...x, note: e.target.value } : x)))}
                  />
                </div>
              ))}
            </div>
            <button className="btn mt-4 w-full" onClick={() => setShowCart(false)}>
              Done
            </button>
          </div>
        </div>
      )}

      {sizing && (
        <SizePicker
          item={sizing}
          currency={currency}
          inCart={(id) => cart.filter((l) => l.item.id === id).reduce((s, l) => s + l.qty, 0)}
          onCancel={() => setSizing(null)}
          onPick={(id) => {
            setSizing(null);
            const size = menu.find((x) => x.id === id);
            if (size) tap(size);
          }}
        />
      )}
      {weighing && (
        <WeightPicker
          item={weighing}
          currency={currency}
          onCancel={() => setWeighing(null)}
          onDone={(kg) => {
            const w = weighing;
            setCart((c) => [...c, { key: `${w.id}|w${Date.now()}`, item: w, options: [], qty: Math.round(kg * 1000) / 1000, note: "" }]);
            setWeighing(null);
          }}
        />
      )}
      {picking && (
        <OptionPicker
          item={picking}
          currency={currency}
          onCancel={() => setPicking(null)}
          onAdd={(opts) => {
            add(picking, opts);
            setPicking(null);
          }}
        />
      )}
    </div>
  );
}
