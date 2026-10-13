"use client";

import { useEffect, useMemo, useState, useTransition } from "react";
import { money } from "@/lib/format";
import { guestOrderStatus, placeGuestOrder } from "../actions";

type Option = { id: string; name: string; price_delta: number };
type Group = { id: string; name: string; min: number; max: number; options: Option[] };
/** `sub`: the sub-category the dish sits in (shown as a heading), or null for the main category itself. */
type Item = { id: string; name: string; name_local: string | null; is_veg: boolean | null; price: number; option_groups: Group[]; sub?: string | null };
export type GuestMenu = {
  restaurant: string;
  outlet: string;
  currency: string;
  table: string;
  /** A self-order kiosk at the counter, not a table: one guest after another, takeaway, pay at the counter. */
  kiosk?: boolean;
  categories: { id: string; name: string; items: Item[] }[];
};
type Line = { key: string; item: Item; qty: number; options: Option[] };
type Sent = { id: string; key: string; total: number; status: "pending" | "accepted" | "rejected"; reason?: string | null; bill?: string | null; tokenNo?: number | null; at?: number };

const unit = (l: { item: Item; options: Option[] }) => Number(l.item.price) + l.options.reduce((s, o) => s + Number(o.price_delta), 0);

export function GuestOrder({ token, menu }: { token: string; menu: GuestMenu }) {
  const [cat, setCat] = useState(menu.categories[0]?.id ?? "");
  const [cart, setCart] = useState<Record<string, Line>>({});
  const [picking, setPicking] = useState<Item | null>(null);
  const [name, setName] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [sent, setSent] = useState<Sent[]>([]);
  const [cartOpen, setCartOpen] = useState(false);
  const [pending, start] = useTransition();
  const m = (n: number) => money(n, menu.currency);

  const lines = Object.values(cart);
  const count = lines.reduce((s, l) => s + l.qty, 0);
  const subtotal = lines.reduce((s, l) => s + unit(l) * l.qty, 0);
  const items = useMemo(() => menu.categories.find((c) => c.id === cat)?.items ?? [], [menu, cat]);

  // Check every 5 seconds whether the staff accepted the orders still waiting.
  useEffect(() => {
    if (!sent.some((s) => s.status === "pending")) return;
    const t = setInterval(async () => {
      const next = await Promise.all(
        sent.map(async (s) => {
          if (s.status !== "pending") return s;
          const r = await guestOrderStatus(s.id, s.key);
          return r ? { ...s, status: r.status, reason: r.reason, bill: r.bill_number, tokenNo: r.token_no } : s;
        }),
      );
      setSent(next);
    }, 5000);
    return () => clearInterval(t);
  }, [sent]);

  // Kiosk: the screen clears itself for the next guest — 90 seconds after the order is confirmed (or 3 minutes after sending).
  useEffect(() => {
    if (!menu.kiosk || sent.length === 0) return;
    const last = sent[0];
    const wait = last.status === "pending" ? 180000 : 90000;
    const t = setTimeout(() => {
      setSent([]);
      setName("");
      setCat(menu.categories[0]?.id ?? "");
    }, wait);
    return () => clearTimeout(t);
  }, [sent, menu]);

  function add(item: Item, options: Option[]) {
    const key = item.id + "|" + options.map((o) => o.id).sort().join(",");
    setCart((c) => ({ ...c, [key]: { key, item, options, qty: Math.min(20, (c[key]?.qty ?? 0) + 1) } }));
  }
  function change(key: string, d: number) {
    setCart((c) => {
      const l = c[key];
      if (!l) return c;
      const qty = Math.min(20, l.qty + d);
      const next = { ...c };
      if (qty <= 0) delete next[key];
      else next[key] = { ...l, qty };
      return next;
    });
  }
  function send() {
    setError(null);
    start(async () => {
      const r = await placeGuestOrder(
        token,
        lines.map((l) => ({ product_id: l.item.id, qty: l.qty, options: l.options.map((o) => o.id), note: "" })),
        name,
        note,
      );
      if (!r.ok) return setError(r.error);
      setSent((s) => (menu.kiosk ? [{ id: r.id, key: r.key, total: r.total, status: "pending" }] : [{ id: r.id, key: r.key, total: r.total, status: "pending" }, ...s]));
      setCart({});
      setNote("");
      setCartOpen(false);
    });
  }

  return (
    <main className="mx-auto min-h-screen max-w-lg pb-28" style={{ background: "var(--color-ground)" }}>
      <header className="px-4 pb-3 pt-4 text-white" style={{ background: "var(--color-brand)" }}>
        <div className="font-display text-xl font-bold">{menu.restaurant}</div>
        <div className="text-sm opacity-85">
          {menu.kiosk ? `Order here · ${menu.outlet}` : `Table ${menu.table} · ${menu.outlet}`}
        </div>
      </header>

      {menu.kiosk && sent[0] && (
        <div role="status" className="mx-4 mt-3 rounded-2xl px-4 py-5 text-center" style={{ background: sent[0].status === "rejected" ? "var(--color-bad-soft)" : sent[0].status === "accepted" ? "var(--color-ok-soft)" : "var(--color-warn-soft)" }}>
          {sent[0].status === "pending" && (
            <>
              <div className="text-lg font-bold">Order sent</div>
              <div className="mt-1 text-sm">Please wait a moment while the counter confirms it. Total {m(sent[0].total)}.</div>
            </>
          )}
          {sent[0].status === "accepted" && (
            <>
              <div className="text-sm font-semibold">Your number</div>
              <div className="font-display text-5xl font-bold tabular-nums">{sent[0].tokenNo ?? sent[0].bill?.split("-").pop() ?? ""}</div>
              <div className="mt-1 text-sm">Bill {sent[0].bill} · please pay {m(sent[0].total)} at the counter. We&rsquo;ll call your number when it&rsquo;s ready.</div>
            </>
          )}
          {sent[0].status === "rejected" && <div className="text-sm font-semibold">Order not accepted{sent[0].reason ? `: ${sent[0].reason}` : ""}. Please ask at the counter.</div>}
          <button className="btn mt-3" onClick={() => { setSent([]); setName(""); }}>
            Start a new order
          </button>
        </div>
      )}

      {!menu.kiosk && sent.map((s) => (
        <div
          key={s.id}
          role="status"
          className="mx-4 mt-3 rounded-2xl px-4 py-3 text-sm font-semibold"
          style={{
            background: s.status === "accepted" ? "var(--color-ok-soft)" : s.status === "rejected" ? "var(--color-bad-soft)" : "var(--color-warn-soft)",
          }}
        >
          {s.status === "pending" && "Order sent — waiting for the staff to confirm…"}
          {s.status === "accepted" && "Order confirmed — it is being prepared. Pay at the counter or to your server."}
          {s.status === "rejected" && `Order not accepted${s.reason ? `: ${s.reason}` : ""}. Please ask the staff.`}
        </div>
      ))}

      <nav className="sticky top-0 z-10 flex gap-2 overflow-x-auto px-4 py-3" style={{ background: "var(--color-ground)" }}>
        {menu.categories.map((c) => (
          <button
            key={c.id}
            onClick={() => setCat(c.id)}
            className="shrink-0 rounded-full border px-4 py-2 text-sm font-bold"
            style={
              c.id === cat
                ? { background: "var(--color-brand)", color: "#fff", borderColor: "var(--color-brand)" }
                : { background: "var(--color-surface)", borderColor: "var(--color-line)" }
            }
          >
            {c.name}
          </button>
        ))}
      </nav>

      <ul className="space-y-2 px-4">
        {items.map((it, i) => (
          <li key={it.id} className="list-none">
            {(it.sub ?? null) !== (i > 0 ? (items[i - 1].sub ?? null) : null) && it.sub && (
              <h2 className="px-1 pb-1 pt-3 text-sm font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
                {it.sub}
              </h2>
            )}
            <div className="card flex items-center justify-between gap-3 p-3">
            <div className="min-w-0">
              <div className="font-semibold">
                {it.is_veg !== null && (
                  <span
                    aria-label={it.is_veg ? "Veg" : "Non-veg"}
                    className="mr-1.5 inline-block h-2.5 w-2.5 rounded-full align-middle"
                    style={{ background: it.is_veg ? "var(--color-ok)" : "var(--color-chilli)" }}
                  />
                )}
                {it.name}
              </div>
              {it.name_local && <div className="text-sm" style={{ color: "var(--color-ink-3)" }}>{it.name_local}</div>}
              <div className="text-sm font-bold tabular-nums">{m(Number(it.price))}</div>
            </div>
            <button
              className="btn btn-pay h-10 min-h-0 shrink-0 px-4 text-sm"
              onClick={() => (it.option_groups.length ? setPicking(it) : add(it, []))}
            >
              Add
            </button>
            </div>
          </li>
        ))}
      </ul>

      {count > 0 && (
        <div className="fixed inset-x-0 bottom-0 mx-auto max-w-lg p-3">
          <button
            className="btn btn-primary w-full justify-between px-5 text-base"
            onClick={() => setCartOpen(true)}
          >
            <span>View order ({count})</span>
            <span className="tabular-nums">{m(subtotal)}</span>
          </button>
        </div>
      )}

      {cartOpen && (
        <div className="fixed inset-0 z-40 flex items-end justify-center" style={{ background: "rgba(10,8,20,.5)" }} onClick={() => setCartOpen(false)}>
          <div className="w-full max-w-lg rounded-t-3xl p-4" style={{ background: "var(--color-surface)" }} onClick={(e) => e.stopPropagation()}>
            <h2 className="mb-3 text-lg font-bold">Your order</h2>
            <ul className="mb-3 max-h-[40vh] space-y-2 overflow-y-auto">
              {lines.map((l) => (
                <li key={l.key} className="flex items-center justify-between gap-2">
                  <div className="min-w-0 text-sm">
                    <div className="font-semibold">{l.item.name}</div>
                    {l.options.length > 0 && <div style={{ color: "var(--color-ink-3)" }}>{l.options.map((o) => o.name).join(", ")}</div>}
                  </div>
                  <div className="flex items-center gap-2">
                    <button className="btn h-9 min-h-0 w-9 border p-0" style={{ borderColor: "var(--color-line)" }} onClick={() => change(l.key, -1)} aria-label="One less">−</button>
                    <span className="w-6 text-center font-bold tabular-nums">{l.qty}</span>
                    <button className="btn h-9 min-h-0 w-9 border p-0" style={{ borderColor: "var(--color-line)" }} onClick={() => change(l.key, 1)} aria-label="One more">+</button>
                  </div>
                </li>
              ))}
            </ul>
            <input className="field mb-2" placeholder="Your name (optional)" maxLength={60} value={name} onChange={(e) => setName(e.target.value)} />
            <input className="field mb-3" placeholder="Note for the kitchen (optional)" maxLength={200} value={note} onChange={(e) => setNote(e.target.value)} />
            <p className="mb-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
              Items {m(subtotal)} before tax and charges. The staff confirm your order; you pay at the counter or to your server.
            </p>
            {error && <p role="alert" className="mb-2 text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{error}</p>}
            <button className="btn btn-pay w-full text-base" disabled={pending || count === 0} onClick={send}>
              {pending ? "Sending…" : "Send order"}
            </button>
          </div>
        </div>
      )}

      {picking && <OptionPicker item={picking} currency={menu.currency} onClose={() => setPicking(null)} onAdd={(opts) => { add(picking, opts); setPicking(null); }} />}
    </main>
  );
}

function OptionPicker({ item, currency, onClose, onAdd }: { item: Item; currency: string; onClose: () => void; onAdd: (o: Option[]) => void }) {
  const [chosen, setChosen] = useState<Record<string, string[]>>({});
  const ok = item.option_groups.every((g) => {
    const n = (chosen[g.id] ?? []).length;
    return n >= g.min && n <= g.max;
  });
  const toggle = (g: Group, id: string) =>
    setChosen((c) => {
      const cur = c[g.id] ?? [];
      if (cur.includes(id)) return { ...c, [g.id]: cur.filter((x) => x !== id) };
      if (g.max === 1) return { ...c, [g.id]: [id] };
      if (cur.length >= g.max) return c;
      return { ...c, [g.id]: [...cur, id] };
    });
  const all = item.option_groups.flatMap((g) => g.options.filter((o) => (chosen[g.id] ?? []).includes(o.id)));
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center" style={{ background: "rgba(10,8,20,.5)" }} onClick={onClose}>
      <div className="w-full max-w-lg rounded-t-3xl p-4" style={{ background: "var(--color-surface)" }} onClick={(e) => e.stopPropagation()}>
        <h2 className="mb-3 text-lg font-bold">{item.name}</h2>
        <div className="max-h-[55vh] space-y-4 overflow-y-auto">
          {item.option_groups.map((g) => (
            <fieldset key={g.id}>
              <legend className="mb-2 text-sm font-bold">
                {g.name}{" "}
                <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>
                  {g.min > 0 ? `choose ${g.min === g.max ? g.min : `${g.min}–${g.max}`}` : g.max < 99 ? `up to ${g.max}` : "optional"}
                </span>
              </legend>
              <div className="flex flex-wrap gap-2">
                {g.options.map((o) => {
                  const on = (chosen[g.id] ?? []).includes(o.id);
                  return (
                    <button
                      key={o.id}
                      onClick={() => toggle(g, o.id)}
                      aria-pressed={on}
                      className="rounded-xl border px-3 py-2 text-sm font-semibold"
                      style={on ? { background: "var(--color-brand-soft)", borderColor: "var(--color-brand)" } : { borderColor: "var(--color-line)" }}
                    >
                      {o.name}
                      {Number(o.price_delta) !== 0 && ` +${money(Number(o.price_delta), currency)}`}
                    </button>
                  );
                })}
              </div>
            </fieldset>
          ))}
        </div>
        <button className="btn btn-pay mt-4 w-full" disabled={!ok} onClick={() => onAdd(all)}>
          Add to order
        </button>
      </div>
    </div>
  );
}
