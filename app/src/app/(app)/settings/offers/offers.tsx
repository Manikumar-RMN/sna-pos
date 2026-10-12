"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { ConfirmButton } from "../confirm-button";
import { deleteOffer, saveOffer, type OfferInput } from "./actions";

export type Offer = {
  id: string;
  name: string;
  days: number[];
  start_time: string;
  end_time: string;
  kind: "percent_off" | "price";
  value: number;
  product_ids: string[];
  category_ids: string[];
  branch_id: string | null;
  valid_from: string | null;
  valid_to: string | null;
  is_active: boolean;
};
type Cat = { id: string; name: string; parent_id: string | null };
type Dish = { id: string; name: string; price: number; category_id: string };

const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const hm = (t: string) => t.slice(0, 5);

function daysText(d: number[]) {
  const s = [...d].sort();
  if (s.length === 7) return "Every day";
  if (s.join() === "1,2,3,4,5") return "Mon–Fri";
  if (s.join() === "6,7") return "Sat–Sun";
  return s.map((x) => DAYS[x - 1]).join(", ");
}

export function Offers({
  canEdit,
  currency,
  offers,
  categories,
  products,
  branches,
}: {
  canEdit: boolean;
  currency: string;
  offers: Offer[];
  categories: Cat[];
  products: Dish[];
  branches: { id: string; name: string }[];
}) {
  const [editing, setEditing] = useState<Offer | "new" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();
  const catName = (id: string) => {
    const c = categories.find((x) => x.id === id);
    const p = c?.parent_id ? categories.find((x) => x.id === c.parent_id) : null;
    return c ? (p ? `${p.name} › ${c.name}` : c.name) : "—";
  };
  const what = (o: Offer) => {
    if (!o.product_ids.length && !o.category_ids.length) return "Whole menu";
    const parts = [
      ...o.category_ids.map(catName),
      ...o.product_ids.map((id) => products.find((p) => p.id === id)?.name ?? "—"),
    ];
    return parts.length > 4 ? `${parts.slice(0, 4).join(", ")} and ${parts.length - 4} more` : parts.join(", ");
  };

  return (
    <div className="card overflow-hidden">
      <div className="flex items-center justify-between gap-3 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)" }}>
        <div className="text-sm font-bold">Offers</div>
        {canEdit && (
          <button className="btn" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)", minHeight: 40, padding: "0 12px" }} onClick={() => setEditing("new")}>
            + New offer
          </button>
        )}
      </div>
      {offers.length === 0 ? (
        <p className="px-4 py-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
          No offers yet. Example: <b>Happy hour</b>, Mon–Fri 4:00 p.m. to 7:00 p.m., 30% off the Drinks category.
        </p>
      ) : (
        offers.map((o) => (
          <div key={o.id} className="flex flex-wrap items-center justify-end gap-3 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)", opacity: o.is_active ? 1 : 0.55 }}>
            <div className="min-w-0 flex-1">
              <div className="text-sm font-semibold">
                {o.name}
                {!o.is_active && <span className="ml-2 text-[11px] font-normal">(switched off)</span>}
              </div>
              <div className="text-xs" style={{ color: "var(--color-ink-2)" }}>
                {daysText(o.days)} · {hm(o.start_time)}–{hm(o.end_time)} ·{" "}
                <b>{o.kind === "percent_off" ? `${Number(o.value)}% off` : `${money(Number(o.value), currency)} each`}</b> · {what(o)}
                {o.branch_id && ` · ${branches.find((b) => b.id === o.branch_id)?.name ?? "one outlet"} only`}
                {(o.valid_from || o.valid_to) && ` · ${o.valid_from ?? "…"} to ${o.valid_to ?? "…"}`}
              </div>
            </div>
            {canEdit && (
              <>
                <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setEditing(o)}>
                  Edit
                </button>
                <ConfirmButton
                  question={`Delete the offer ${o.name}?`}
                  yesLabel="Yes, delete"
                  disabled={pending}
                  onConfirm={() =>
                    start(async () => {
                      const r = await deleteOffer(o.id);
                      setError(r.error);
                      if (!r.error) router.refresh();
                    })
                  }
                >
                  Delete
                </ConfirmButton>
              </>
            )}
          </div>
        ))
      )}
      {error && (
        <p className="px-4 py-2 text-sm" style={{ color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      {editing && (
        <OfferModal
          offer={editing === "new" ? null : editing}
          currency={currency}
          categories={categories}
          products={products}
          branches={branches}
          catName={catName}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

function OfferModal({
  offer,
  currency,
  categories,
  products,
  branches,
  catName,
  onClose,
}: {
  offer: Offer | null;
  currency: string;
  categories: Cat[];
  products: Dish[];
  branches: { id: string; name: string }[];
  catName: (id: string) => string;
  onClose: () => void;
}) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [f, setF] = useState<OfferInput>(() => ({
    id: offer?.id ?? null,
    name: offer?.name ?? "Happy hour",
    days: offer?.days ?? [1, 2, 3, 4, 5, 6, 7],
    start_time: hm(offer?.start_time ?? "16:00"),
    end_time: hm(offer?.end_time ?? "19:00"),
    kind: offer?.kind ?? "percent_off",
    value: Number(offer?.value ?? 20),
    product_ids: offer?.product_ids ?? [],
    category_ids: offer?.category_ids ?? [],
    branch_id: offer?.branch_id ?? null,
    valid_from: offer?.valid_from ?? null,
    valid_to: offer?.valid_to ?? null,
    is_active: offer?.is_active ?? true,
  }));
  const [scope, setScope] = useState<"all" | "pick">(offer && (offer.product_ids.length || offer.category_ids.length) ? "pick" : "all");
  const [q, setQ] = useState("");
  const set = (patch: Partial<OfferInput>) => setF((x) => ({ ...x, ...patch }));
  const toggle = (list: string[], id: string) => (list.includes(id) ? list.filter((x) => x !== id) : [...list, id]);
  const shownDishes = products.filter((p) => !q.trim() || p.name.toLowerCase().includes(q.trim().toLowerCase()));

  function save() {
    setError(null);
    const input = { ...f, ...(scope === "all" ? { product_ids: [], category_ids: [] } : {}) };
    if (scope === "pick" && !input.product_ids.length && !input.category_ids.length) return setError("Tick at least one category or dish, or choose Whole menu.");
    start(async () => {
      const r = await saveOffer(input);
      if (r.error) return setError(r.error);
      router.refresh();
      onClose();
    });
  }

  return (
    <div
      style={{ position: "fixed", inset: 0, background: "rgba(10,8,20,.55)", display: "grid", placeItems: "center", padding: 16, zIndex: 50 }}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="card" role="dialog" aria-label="Offer" style={{ width: "100%", maxWidth: 560, padding: 18, background: "var(--color-surface)", maxHeight: "92vh", overflowY: "auto" }}>
        <h3 className="mb-4 text-lg font-bold">{offer ? "Edit offer" : "New offer"}</h3>

        <label className="mb-1.5 block text-sm font-semibold">Name</label>
        <input className="field mb-4" maxLength={40} value={f.name} onChange={(e) => set({ name: e.target.value })} placeholder="Happy hour" />

        <div className="mb-1.5 text-sm font-semibold">Days</div>
        <div className="mb-4 flex flex-wrap gap-1.5">
          {DAYS.map((d, i) => {
            const on = f.days.includes(i + 1);
            return (
              <button
                key={d}
                type="button"
                aria-pressed={on}
                onClick={() => set({ days: on ? f.days.filter((x) => x !== i + 1) : [...f.days, i + 1] })}
                className="rounded-lg border px-3 py-2 text-sm font-semibold"
                style={{ borderColor: on ? "var(--color-brand)" : "var(--color-line)", background: on ? "var(--color-brand-soft)" : "transparent" }}
              >
                {d}
              </button>
            );
          })}
        </div>

        <div className="mb-4 grid grid-cols-2 gap-3">
          <label className="text-sm font-semibold">
            From
            <input type="time" className="field mt-1.5" value={f.start_time} onChange={(e) => set({ start_time: e.target.value })} />
          </label>
          <label className="text-sm font-semibold">
            To
            <input type="time" className="field mt-1.5" value={f.end_time} onChange={(e) => set({ end_time: e.target.value })} />
          </label>
        </div>
        <p className="-mt-2 mb-4 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
          An offer can run past midnight (10 p.m. to 1 a.m.); it then belongs to the day it starts.
        </p>

        <div className="mb-4 grid grid-cols-2 gap-3">
          <label className="text-sm font-semibold">
            Offer
            <select className="field mt-1.5" value={f.kind} onChange={(e) => set({ kind: e.target.value as OfferInput["kind"] })}>
              <option value="percent_off">Percent off</option>
              <option value="price">One fixed price</option>
            </select>
          </label>
          <label className="text-sm font-semibold">
            {f.kind === "percent_off" ? "Percent off" : `Price (${currency})`}
            <input className="field mt-1.5" inputMode="decimal" value={String(f.value)} onChange={(e) => set({ value: Number(e.target.value) || 0 })} />
          </label>
        </div>

        <div className="mb-1.5 text-sm font-semibold">For</div>
        <div className="mb-2 flex gap-4 text-sm">
          <label className="flex items-center gap-2">
            <input type="radio" checked={scope === "all"} onChange={() => setScope("all")} disabled={f.kind === "price"} /> Whole menu
          </label>
          <label className="flex items-center gap-2">
            <input type="radio" checked={scope === "pick" || f.kind === "price"} onChange={() => setScope("pick")} /> Chosen categories and dishes
          </label>
        </div>
        {(scope === "pick" || f.kind === "price") && (
          <div className="mb-4 rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
            {f.kind === "percent_off" && (
              <>
                <div className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                  Categories (a main category includes its sub-categories)
                </div>
                <div className="mb-3 flex flex-wrap gap-x-4 gap-y-1.5">
                  {categories.map((c) => (
                    <label key={c.id} className="flex items-center gap-2 text-sm">
                      <input type="checkbox" className="h-4 w-4" checked={f.category_ids.includes(c.id)} onChange={() => set({ category_ids: toggle(f.category_ids, c.id) })} />
                      {catName(c.id)}
                    </label>
                  ))}
                </div>
              </>
            )}
            <div className="mb-1 text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Dishes (a dish includes all its sizes)
            </div>
            <input className="field mb-2 h-9 text-sm" placeholder="Search dishes" value={q} onChange={(e) => setQ(e.target.value)} />
            <div className="max-h-48 space-y-1 overflow-y-auto">
              {shownDishes.map((p) => (
                <label key={p.id} className="flex items-center gap-2 text-sm">
                  <input type="checkbox" className="h-4 w-4" checked={f.product_ids.includes(p.id)} onChange={() => set({ product_ids: toggle(f.product_ids, p.id) })} />
                  <span className="flex-1">{p.name}</span>
                  <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                    {money(p.price, currency)}
                  </span>
                </label>
              ))}
            </div>
          </div>
        )}

        {branches.length > 1 && (
          <label className="mb-4 block text-sm font-semibold">
            Outlets
            <select className="field mt-1.5" value={f.branch_id ?? ""} onChange={(e) => set({ branch_id: e.target.value || null })}>
              <option value="">All outlets</option>
              {branches.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.name} only
                </option>
              ))}
            </select>
          </label>
        )}

        <div className="mb-4 grid grid-cols-2 gap-3">
          <label className="text-sm font-semibold">
            Starts on <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(optional)</span>
            <input type="date" className="field mt-1.5" value={f.valid_from ?? ""} onChange={(e) => set({ valid_from: e.target.value || null })} />
          </label>
          <label className="text-sm font-semibold">
            Ends on <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(optional)</span>
            <input type="date" className="field mt-1.5" value={f.valid_to ?? ""} onChange={(e) => set({ valid_to: e.target.value || null })} />
          </label>
        </div>

        <label className="mb-4 flex items-center gap-2 text-sm">
          <input type="checkbox" className="h-4 w-4" checked={f.is_active} onChange={(e) => set({ is_active: e.target.checked })} />
          Offer is on
        </label>

        {error && (
          <p className="mb-3 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
            {error}
          </p>
        )}
        <div className="flex gap-2">
          <button type="button" className="btn" style={{ flex: "none", padding: "0 16px" }} onClick={onClose}>
            Cancel
          </button>
          <button type="button" className="btn btn-primary" style={{ flex: 1 }} disabled={pending} onClick={save}>
            {pending ? "Saving…" : "Save offer"}
          </button>
        </div>
      </div>
    </div>
  );
}
