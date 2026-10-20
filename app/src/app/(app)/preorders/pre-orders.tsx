"use client";

import { useMemo, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { billPreOrder, cancelPreOrder, savePreOrder, takeAdvance } from "./actions";
import { OptionPicker, SizePicker, WeightPicker, qtyText, type ChosenOption, type MenuItem } from "../pos/pos-terminal";

export type PreOrder = {
  id: string;
  number: number;
  guest_name: string;
  guest_phone: string | null;
  due_at: string;
  order_type: "takeaway" | "delivery" | "dine_in";
  address: string | null;
  note: string | null;
  estimate: number;
  status: "booked" | "billed" | "cancelled";
  order_id: string | null;
  bill_number: string | null;
  advance: number;
  lines: { name: string; qty: number; note: string | null; options: string | null }[];
};
type Method = { id: string; name: string; kind: string };
type Line = { key: string; item: MenuItem; options: ChosenOption[]; qty: number; note: string };

export function PreOrders({
  currency,
  canPay,
  showDone,
  orders,
  methods,
  menu,
  categoryParents,
  timezone,
}: {
  currency: string;
  canPay: boolean;
  showDone: boolean;
  orders: PreOrder[];
  methods: Method[];
  menu: MenuItem[];
  categoryParents: Record<string, { id: string; name: string }>;
  timezone: string;
}) {
  const [creating, setCreating] = useState(false);
  const [advanceFor, setAdvanceFor] = useState<PreOrder | null>(null);
  const [cancelFor, setCancelFor] = useState<PreOrder | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  const m = (n: number) => money(n, currency);
  const when = (iso: string) =>
    new Intl.DateTimeFormat("en-IN", { timeZone: timezone, weekday: "short", day: "numeric", month: "short", hour: "numeric", minute: "2-digit" }).format(new Date(iso));
  const dayKey = (iso: string) => new Intl.DateTimeFormat("en-CA", { timeZone: timezone }).format(new Date(iso));
  const today = dayKey(new Date().toISOString());

  const groups = useMemo(() => {
    const g: { key: string; label: string; items: PreOrder[] }[] = [];
    for (const o of orders) {
      const k = dayKey(o.due_at);
      let x = g.find((y) => y.key === k);
      if (!x) {
        x = {
          key: k,
          label: k === today ? "Today" : new Intl.DateTimeFormat("en-IN", { timeZone: timezone, weekday: "long", day: "numeric", month: "long" }).format(new Date(o.due_at)),
          items: [],
        };
        g.push(x);
      }
      x.items.push(o);
    }
    return g;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orders, timezone]);

  return (
    <div className="mx-auto max-w-4xl">
      <div className="mb-4 flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold tracking-tight">Pre-orders</h1>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Cakes and party orders booked for later, with an advance. The bill is made when the guest collects.
          </p>
        </div>
        <div className="flex gap-2">
          <Link href={showDone ? "/preorders" : "/preorders?show=done"} className="btn" style={{ minHeight: 40, padding: "0 12px" }}>
            {showDone ? "Upcoming" : "Done and cancelled"}
          </Link>
          {!showDone && (
            <button className="btn btn-primary" style={{ minHeight: 40, padding: "0 14px" }} onClick={() => setCreating(true)}>
              + New pre-order
            </button>
          )}
        </div>
      </div>
      {msg && (
        <div role="status" className="mb-3 rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: msg.ok ? "var(--color-ok-soft)" : "var(--color-bad-soft)", color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}>
          {msg.text}
        </div>
      )}
      {orders.length === 0 && (
        <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
          {showDone ? "No finished or cancelled pre-orders in the last 60 days." : "No pre-orders waiting. Tap “New pre-order” to book one."}
        </div>
      )}
      <div className="space-y-5">
        {groups.map((g) => (
          <section key={g.key}>
            <h2 className="mb-2 text-xs font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
              {g.label}
            </h2>
            <div className="space-y-2">
              {g.items.map((o) => {
                const late = o.status === "booked" && new Date(o.due_at).getTime() < Date.now();
                return (
                  <div key={o.id} className="card p-4" style={late ? { borderColor: "var(--color-bad)" } : undefined}>
                    <div className="flex flex-wrap items-start justify-between gap-2">
                      <div>
                        <div className="font-bold">
                          PO-{o.number} · {o.guest_name}
                          {o.guest_phone && <span className="ml-2 text-sm font-normal" style={{ color: "var(--color-ink-3)" }}>{o.guest_phone}</span>}
                        </div>
                        <div className="text-sm" style={{ color: late ? "var(--color-bad)" : "var(--color-ink-2)" }}>
                          Due {when(o.due_at)} · {o.order_type === "delivery" ? "Delivery" : "Pick-up"}
                          {late && " · overdue"}
                        </div>
                      </div>
                      <div className="text-right text-sm">
                        <div>
                          About <b>{m(o.estimate)}</b>
                        </div>
                        <div style={{ color: o.advance > 0 ? "var(--color-ok)" : "var(--color-ink-3)" }}>Advance {m(o.advance)}</div>
                      </div>
                    </div>
                    <ul className="mt-2 list-disc pl-5 text-sm">
                      {o.lines.map((l, i) => (
                        <li key={i}>
                          {qtyText(Number(l.qty), !Number.isInteger(Number(l.qty)))} × {l.name}
                          {l.options && <span style={{ color: "var(--color-ink-3)" }}> ({l.options})</span>}
                          {l.note && <span style={{ color: "var(--color-ink-3)" }}> — {l.note}</span>}
                        </li>
                      ))}
                    </ul>
                    {o.note && (
                      <p className="mt-2 rounded-lg px-3 py-2 text-sm" style={{ background: "var(--color-ground)" }}>
                        <b>Note:</b> {o.note}
                      </p>
                    )}
                    {o.address && o.order_type === "delivery" && (
                      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
                        Deliver to: {o.address}
                      </p>
                    )}
                    {o.status === "booked" ? (
                      <div className="mt-3 flex flex-wrap gap-2">
                        <button
                          className="btn btn-primary"
                          style={{ minHeight: 40, padding: "0 14px" }}
                          disabled={pending}
                          onClick={() =>
                            start(async () => {
                              const r = await billPreOrder(o.id);
                              if (!r.ok) return setMsg({ ok: false, text: r.error });
                              // The advance was more than the bill: stay here so the cashier sees how much to hand back.
                              if (r.leftOver > 0) return setMsg({ ok: true, text: `Bill ${r.billNumber} made. The advance was ${m(r.leftOver)} more than the bill: give ${m(r.leftOver)} back to the guest. It is already written down.` });
                              router.push(`/bills/${r.orderId}`);
                            })
                          }
                        >
                          Collected · bill now
                        </button>
                        {canPay && (
                          <button className="btn" style={{ minHeight: 40, padding: "0 14px" }} onClick={() => setAdvanceFor(o)}>
                            Take advance
                          </button>
                        )}
                        <button className="btn" style={{ minHeight: 40, padding: "0 14px", color: "var(--color-bad)" }} onClick={() => setCancelFor(o)}>
                          Cancel
                        </button>
                      </div>
                    ) : (
                      <div className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {o.status === "billed" && o.order_id ? (
                          <div className="flex flex-wrap items-center gap-3">
                            <Link href={`/bills/${o.order_id}`} className="font-semibold" style={{ color: "var(--color-brand)" }}>
                              Billed as {o.bill_number} →
                            </Link>
                          </div>
                        ) : (
                          "Cancelled"
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </section>
        ))}
      </div>

      {creating && (
        <NewPreOrder
          currency={currency}
          menu={menu}
          categoryParents={categoryParents}
          methods={methods}
          canPay={canPay}
          onClose={() => setCreating(false)}
          onDone={(text) => {
            setCreating(false);
            setMsg({ ok: true, text });
            router.refresh();
          }}
        />
      )}
      {advanceFor && (
        <MoneyDialog
          title={`Advance for PO-${advanceFor.number}`}
          hint={`Held so far: ${m(advanceFor.advance)} of about ${m(advanceFor.estimate)}.`}
          methods={methods}
          askAmount
          action="Take advance"
          onClose={() => setAdvanceFor(null)}
          onConfirm={async (methodId, amount, ref) => {
            const r = await takeAdvance(advanceFor.id, methodId, amount, ref);
            if (!r.ok) return r.error;
            setAdvanceFor(null);
            setMsg({ ok: true, text: `Advance of ${m(amount)} taken for PO-${advanceFor.number}.` });
            router.refresh();
            return null;
          }}
        />
      )}
      {cancelFor && (
        <MoneyDialog
          title={`Cancel PO-${cancelFor.number}`}
          hint={cancelFor.advance > 0 ? `The advance of ${m(cancelFor.advance)} is given back. Choose how.` : "No advance was taken."}
          methods={cancelFor.advance > 0 ? methods : []}
          askReason
          action="Cancel pre-order"
          danger
          onClose={() => setCancelFor(null)}
          onConfirm={async (methodId, _amount, reason) => {
            const r = await cancelPreOrder(cancelFor.id, reason, methodId || null);
            if (!r.ok) return r.error;
            setCancelFor(null);
            setMsg({ ok: true, text: r.refunded > 0 ? `PO-${cancelFor.number} cancelled. Give back ${m(r.refunded)}.` : `PO-${cancelFor.number} cancelled.` });
            router.refresh();
            return null;
          }}
        />
      )}
    </div>
  );
}

/** Choose a payment method and amount (advance), or a reason and refund method (cancel). */
function MoneyDialog({
  title,
  hint,
  methods,
  askAmount,
  askReason,
  action,
  danger,
  onClose,
  onConfirm,
}: {
  title: string;
  hint: string;
  methods: Method[];
  askAmount?: boolean;
  askReason?: boolean;
  action: string;
  danger?: boolean;
  onClose: () => void;
  onConfirm: (methodId: string, amount: number, text: string) => Promise<string | null>;
}) {
  const [methodId, setMethodId] = useState(methods[0]?.id ?? "");
  const [amount, setAmount] = useState("");
  const [text, setText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <div className="fixed inset-0 z-50 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="card w-full max-w-sm p-5" style={{ background: "var(--color-surface)" }} role="dialog" aria-label={title}>
        <h3 className="text-lg font-bold">{title}</h3>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          {hint}
        </p>
        {methods.length > 0 && (
          <div className="mt-3 flex flex-wrap gap-1.5">
            {methods.map((x) => (
              <button
                key={x.id}
                className="rounded-lg border px-3 py-2 text-sm font-semibold"
                style={{ borderColor: methodId === x.id ? "var(--color-brand)" : "var(--color-line)", background: methodId === x.id ? "var(--color-brand-soft)" : "transparent" }}
                onClick={() => setMethodId(x.id)}
                aria-pressed={methodId === x.id}
              >
                {x.name}
              </button>
            ))}
          </div>
        )}
        {askAmount && (
          <label className="mt-3 block text-sm font-semibold">
            Amount
            <input className="field mt-1.5" inputMode="decimal" autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} />
          </label>
        )}
        <label className="mt-3 block text-sm font-semibold">
          {askReason ? "Reason" : "Reference (optional)"}
          <input className="field mt-1.5" maxLength={askReason ? 200 : 60} value={text} onChange={(e) => setText(e.target.value)} placeholder={askReason ? "Guest changed plans" : "UPI transaction ID"} />
        </label>
        {error && (
          <p className="mt-3 text-sm" role="alert" style={{ color: "var(--color-bad)" }}>
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onClose}>
            Back
          </button>
          <button
            className="btn btn-primary"
            style={{ flex: 1, ...(danger ? { background: "var(--color-bad)" } : {}) }}
            disabled={pending}
            onClick={() =>
              start(async () => {
                const e = await onConfirm(methodId, Number(amount) || 0, text.trim());
                setError(e);
              })
            }
          >
            {pending ? "Saving…" : action}
          </button>
        </div>
      </div>
    </div>
  );
}

/** Book a pre-order: guest, when, dishes, note; then the advance. */
function NewPreOrder({
  currency,
  menu,
  categoryParents,
  methods,
  canPay,
  onClose,
  onDone,
}: {
  currency: string;
  menu: MenuItem[];
  categoryParents: Record<string, { id: string; name: string }>;
  methods: Method[];
  canPay: boolean;
  onClose: () => void;
  onDone: (text: string) => void;
}) {
  const m = (n: number) => money(n, currency);
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [due, setDue] = useState("");
  const [type, setType] = useState<"takeaway" | "delivery">("takeaway");
  const [address, setAddress] = useState("");
  const [note, setNote] = useState("");
  const [cart, setCart] = useState<Line[]>([]);
  const [search, setSearch] = useState("");
  const [sizing, setSizing] = useState<MenuItem | null>(null);
  const [picking, setPicking] = useState<MenuItem | null>(null);
  const [weighing, setWeighing] = useState<MenuItem | null>(null);
  const [advance, setAdvance] = useState("");
  const [methodId, setMethodId] = useState(methods[0]?.id ?? "");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const found = useMemo(() => {
    const q = search.trim().toLowerCase();
    if (!q) return [];
    return menu.filter((x) => !x.variantOf && x.name.toLowerCase().includes(q)).slice(0, 12);
  }, [menu, search]);
  const total = cart.reduce((s, l) => s + l.qty * (l.item.price + l.options.reduce((a, o) => a + o.price, 0)), 0);

  function add(item: MenuItem, options: ChosenOption[], qty = 1) {
    setCart((c) => [...c, { key: `${item.id}|${Date.now()}`, item, options, qty, note: "" }]);
    setSearch("");
  }
  function tap(item: MenuItem) {
    if (item.variants) {
      if (item.variants.length === 1) {
        const only = menu.find((x) => x.id === item.variants![0].id);
        if (only) tap(only);
      } else if (item.variants.length > 1) setSizing(item);
      return;
    }
    if (item.byWeight) return setWeighing(item);
    if (item.groups.length > 0) return setPicking(item);
    add(item, []);
  }

  function save() {
    setError(null);
    if (!due) return setError("Enter when the order is due.");
    if (!cart.length) return setError("Add at least one dish.");
    const dueIso = new Date(due).toISOString();
    start(async () => {
      const r = await savePreOrder({
        guest_name: name,
        guest_phone: phone,
        due_at: dueIso,
        order_type: type,
        address,
        note,
        items: cart.map((l) => ({ product_id: l.item.id, qty: l.qty, options: l.options.map((o) => o.id), note: l.note.trim() || undefined })),
      });
      if (!r.ok) return setError(r.error);
      const adv = Number(advance) || 0;
      if (adv > 0 && canPay) {
        const a = await takeAdvance(r.id, methodId, adv, "");
        if (!a.ok) return onDone(`PO-${r.number} booked, but the advance was not taken: ${a.error}`);
        return onDone(`PO-${r.number} booked for ${name}. Advance ${m(adv)} taken; about ${m(r.estimate - adv)} to collect.`);
      }
      onDone(`PO-${r.number} booked for ${name}. About ${m(r.estimate)} to collect.`);
    });
  }

  void categoryParents;
  return (
    <div className="fixed inset-0 z-40 grid place-items-center p-4" style={{ background: "rgba(10,8,20,.55)" }} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className="card w-full max-w-xl p-5" style={{ background: "var(--color-surface)", maxHeight: "92vh", overflowY: "auto" }} role="dialog" aria-label="New pre-order">
        <h3 className="mb-3 text-lg font-bold">New pre-order</h3>
        <div className="grid grid-cols-2 gap-3">
          <label className="text-sm font-semibold">
            Guest name
            <input className="field mt-1" value={name} onChange={(e) => setName(e.target.value)} maxLength={80} autoFocus />
          </label>
          <label className="text-sm font-semibold">
            Phone
            <input className="field mt-1" inputMode="tel" value={phone} onChange={(e) => setPhone(e.target.value)} maxLength={20} />
          </label>
          <label className="text-sm font-semibold">
            Due on
            <input className="field mt-1" type="datetime-local" value={due} onChange={(e) => setDue(e.target.value)} />
          </label>
          <label className="text-sm font-semibold">
            Pick-up or delivery
            <select className="field mt-1" value={type} onChange={(e) => setType(e.target.value as "takeaway" | "delivery")}>
              <option value="takeaway">Pick-up</option>
              <option value="delivery">Delivery</option>
            </select>
          </label>
        </div>
        {type === "delivery" && (
          <label className="mt-3 block text-sm font-semibold">
            Delivery address
            <input className="field mt-1" value={address} onChange={(e) => setAddress(e.target.value)} maxLength={300} />
          </label>
        )}

        <div className="mt-4 text-sm font-semibold">Dishes</div>
        <input className="field mt-1" placeholder="Type to find a dish, e.g. cake" value={search} onChange={(e) => setSearch(e.target.value)} />
        {found.length > 0 && (
          <div className="mt-1 max-h-48 overflow-y-auto rounded-xl border" style={{ borderColor: "var(--color-line)" }}>
            {found.map((x) => (
              <button key={x.id} className="flex w-full items-center justify-between px-3 py-2 text-left text-sm hover:underline" onClick={() => tap(x)}>
                <span>{x.name}</span>
                <span style={{ color: "var(--color-ink-3)" }}>
                  {x.variants?.length ? `from ${m(x.variants[0].price)}` : m(x.price)}
                  {x.byWeight ? "/kg" : ""}
                </span>
              </button>
            ))}
          </div>
        )}
        <div className="mt-2 space-y-2">
          {cart.map((l) => (
            <div key={l.key} className="rounded-xl border p-2" style={{ borderColor: "var(--color-line)" }}>
              <div className="flex items-center gap-2 text-sm">
                <span className="flex-1">
                  {l.item.name}
                  {l.options.length > 0 && <span style={{ color: "var(--color-ink-3)" }}> ({l.options.map((o) => o.name).join(", ")})</span>}
                </span>
                {l.item.byWeight ? (
                  <span className="font-semibold">{qtyText(l.qty, true)}</span>
                ) : (
                  <input
                    className="field h-8 w-16 text-center"
                    inputMode="numeric"
                    value={String(l.qty)}
                    onChange={(e) => setCart((c) => c.map((x) => (x.key === l.key ? { ...x, qty: Math.max(1, Math.min(999, Number(e.target.value.replace(/\D/g, "")) || 1)) } : x)))}
                    aria-label="Quantity"
                  />
                )}
                <button className="text-sm font-semibold" style={{ color: "var(--color-bad)" }} onClick={() => setCart((c) => c.filter((x) => x.key !== l.key))} aria-label="Remove">
                  ✕
                </button>
              </div>
              <input
                className="field mt-1 h-8 text-xs"
                placeholder="Note for the kitchen (eggless, design, size)"
                maxLength={200}
                value={l.note}
                onChange={(e) => setCart((c) => c.map((x) => (x.key === l.key ? { ...x, note: e.target.value } : x)))}
              />
            </div>
          ))}
        </div>
        <label className="mt-3 block text-sm font-semibold">
          Note on the order <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(e.g. message on the cake)</span>
          <input className="field mt-1" value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} placeholder="Happy Birthday Riya" />
        </label>

        <div className="mt-3 text-sm">
          About <b>{m(Math.round(total * 100) / 100)}</b> before tax and charges.
        </div>
        {canPay && methods.length > 0 && (
          <div className="mt-3 rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
            <div className="text-sm font-semibold">Advance now (optional)</div>
            <div className="mt-2 flex flex-wrap items-center gap-1.5">
              <input className="field h-10 w-28" inputMode="decimal" placeholder="Amount" value={advance} onChange={(e) => setAdvance(e.target.value)} />
              {methods.map((x) => (
                <button
                  key={x.id}
                  className="rounded-lg border px-3 py-2 text-sm font-semibold"
                  style={{ borderColor: methodId === x.id ? "var(--color-brand)" : "var(--color-line)", background: methodId === x.id ? "var(--color-brand-soft)" : "transparent" }}
                  onClick={() => setMethodId(x.id)}
                  aria-pressed={methodId === x.id}
                >
                  {x.name}
                </button>
              ))}
            </div>
          </div>
        )}
        {error && (
          <p className="mt-3 text-sm" role="alert" style={{ color: "var(--color-bad)" }}>
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn-primary" style={{ flex: 1 }} disabled={pending} onClick={save}>
            {pending ? "Booking…" : "Book pre-order"}
          </button>
        </div>
      </div>

      {sizing && (
        <SizePicker
          item={sizing}
          currency={currency}
          inCart={() => 0}
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
            add(weighing, [], Math.round(kg * 1000) / 1000);
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
