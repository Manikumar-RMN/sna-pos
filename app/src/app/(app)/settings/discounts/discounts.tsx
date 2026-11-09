"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import { saveDiscount, saveMaxDiscount, type DiscountInput } from "./actions";

export type DiscountRow = {
  id: string;
  name: string;
  kind: "percent" | "amount";
  value: number;
  valid_from: string | null;
  valid_to: string | null;
  order_types: string[];
  outlet_ids: string[] | null;
  is_active: boolean;
};

const TYPES: { key: string; label: string }[] = [
  { key: "dine_in", label: "Dine-in" },
  { key: "takeaway", label: "Takeaway" },
  { key: "delivery", label: "Delivery" },
];

const blank = (): DiscountInput => ({ id: null, name: "", kind: "percent", value: 10, valid_from: null, valid_to: null, order_types: TYPES.map((t) => t.key), outlet_ids: null, is_active: true });

export function Discounts({
  canEdit,
  currency,
  rows,
  maxPercent,
  branches,
}: {
  canEdit: boolean;
  currency: string;
  rows: DiscountRow[];
  maxPercent: number | null;
  branches: { id: string; name: string }[];
}) {
  const [form, setForm] = useState<DiscountInput | null>(null);
  const [cap, setCap] = useState(maxPercent === null ? "" : String(maxPercent));
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const router = useRouter();

  function save(input: DiscountInput, done?: () => void) {
    start(async () => {
      const r = await saveDiscount(input);
      setError(r.error);
      setNote(r.error ? null : "Saved.");
      if (!r.error) {
        done?.();
        router.refresh();
      }
    });
  }

  const toggle = (list: string[], key: string) => (list.includes(key) ? list.filter((x) => x !== key) : [...list, key]);

  return (
    <div className="space-y-4">
      <div className="card p-4 space-y-2">
        <div className="text-sm font-bold">Maximum discount on a bill</div>
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          No bill may be discounted by more than this percentage, whether the discount is saved or typed. Owners can go above it. Leave empty for no limit.
        </p>
        <div className="flex items-center gap-2">
          <input className="field h-10 w-24 text-sm" inputMode="decimal" placeholder="No limit" value={cap} disabled={!canEdit} onChange={(e) => setCap(e.target.value)} aria-label="Maximum discount percent" />
          <span className="text-sm">%</span>
          {canEdit && (
            <button
              className="btn"
              style={{ minHeight: 40, padding: "0 14px" }}
              disabled={pending}
              onClick={() =>
                start(async () => {
                  const n = cap.trim() === "" ? null : Number(cap);
                  if (n !== null && !(n >= 1 && n <= 100)) return setError("The maximum must be between 1 and 100.");
                  const r = await saveMaxDiscount(n);
                  setError(r.error);
                  setNote(r.error ? null : n === null ? "No limit set." : `Maximum set to ${n}%.`);
                  if (!r.error) router.refresh();
                })
              }
            >
              Save
            </button>
          )}
        </div>
      </div>

      <div className="card overflow-hidden">
        <div className="flex items-center justify-between gap-3 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)" }}>
          <div className="text-sm font-bold">Saved discounts</div>
          {canEdit && (
            <button className="btn" style={{ background: "var(--color-brand-soft)", color: "var(--color-brand)", minHeight: 40, padding: "0 12px" }} onClick={() => { setForm(blank()); setNote(null); }}>
              + New discount
            </button>
          )}
        </div>
        {rows.length === 0 ? (
          <p className="px-4 py-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
            No saved discounts yet. Example: <b>Member</b>, 10%, dine-in and takeaway.
          </p>
        ) : (
          rows.map((d) => (
            <div key={d.id} className="flex flex-wrap items-center justify-end gap-3 px-4 py-3" style={{ borderBottom: "1px solid var(--color-line)", opacity: d.is_active ? 1 : 0.55 }}>
              <div className="min-w-0 flex-1">
                <div className="text-sm font-semibold">
                  {d.name}
                  {!d.is_active && <span className="ml-2 text-[11px] font-normal">(switched off)</span>}
                </div>
                <div className="text-xs" style={{ color: "var(--color-ink-2)" }}>
                  <b>{d.kind === "percent" ? `${Number(d.value)}%` : money(Number(d.value), currency)}</b> · {d.order_types.length === 3 ? "All kinds of bill" : d.order_types.map((t) => TYPES.find((x) => x.key === t)?.label ?? t).join(", ")}
                  {d.outlet_ids && ` · ${d.outlet_ids.map((id) => branches.find((b) => b.id === id)?.name ?? "outlet").join(", ")} only`}
                  {(d.valid_from || d.valid_to) && ` · ${d.valid_from ?? "…"} to ${d.valid_to ?? "…"}`}
                </div>
              </div>
              {canEdit && (
                <>
                  <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => { setForm({ ...d, value: Number(d.value) }); setNote(null); }}>
                    Edit
                  </button>
                  <button
                    className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
                    style={{ borderColor: "var(--color-line)" }}
                    disabled={pending}
                    onClick={() => save({ ...d, value: Number(d.value), is_active: !d.is_active })}
                  >
                    {d.is_active ? "Switch off" : "Switch on"}
                  </button>
                </>
              )}
            </div>
          ))
        )}
      </div>

      {form && (
        <div className="card space-y-3 p-4" role="form" aria-label="Discount">
          <div className="text-sm font-bold">{form.id ? "Edit discount" : "New discount"}</div>
          <label className="block text-xs font-medium">
            Name
            <input className="field mt-1 h-10 text-sm" value={form.name} maxLength={60} placeholder="Member, Staff, Service recovery" onChange={(e) => setForm({ ...form, name: e.target.value })} />
          </label>
          <div className="flex flex-wrap items-end gap-3">
            <label className="block text-xs font-medium">
              Kind
              <select className="field mt-1 h-10 text-sm" value={form.kind} onChange={(e) => setForm({ ...form, kind: e.target.value as "percent" | "amount" })}>
                <option value="percent">Percent of the bill</option>
                <option value="amount">Fixed amount</option>
              </select>
            </label>
            <label className="block text-xs font-medium">
              {form.kind === "percent" ? "Percent" : `Amount (${currency})`}
              <input className="field mt-1 h-10 w-28 text-sm" inputMode="decimal" value={String(form.value)} onChange={(e) => setForm({ ...form, value: Number(e.target.value) })} />
            </label>
            <label className="block text-xs font-medium">
              From (optional)
              <input type="date" className="field mt-1 h-10 text-sm" value={form.valid_from ?? ""} onChange={(e) => setForm({ ...form, valid_from: e.target.value || null })} />
            </label>
            <label className="block text-xs font-medium">
              To (optional)
              <input type="date" className="field mt-1 h-10 text-sm" value={form.valid_to ?? ""} onChange={(e) => setForm({ ...form, valid_to: e.target.value || null })} />
            </label>
          </div>
          <div>
            <div className="text-xs font-medium">Kinds of bill</div>
            <div className="mt-1 flex flex-wrap gap-3 text-sm">
              {TYPES.map((t) => (
                <label key={t.key} className="flex items-center gap-1.5">
                  <input type="checkbox" className="h-5 w-5" checked={form.order_types.includes(t.key)} onChange={() => setForm({ ...form, order_types: toggle(form.order_types, t.key) })} />
                  {t.label}
                </label>
              ))}
            </div>
          </div>
          {branches.length > 1 && (
            <div>
              <div className="text-xs font-medium">Outlets (none ticked = all outlets)</div>
              <div className="mt-1 flex flex-wrap gap-3 text-sm">
                {branches.map((b) => (
                  <label key={b.id} className="flex items-center gap-1.5">
                    <input
                      type="checkbox"
                      className="h-5 w-5"
                      checked={!!form.outlet_ids?.includes(b.id)}
                      onChange={() => {
                        const next = toggle(form.outlet_ids ?? [], b.id);
                        setForm({ ...form, outlet_ids: next.length ? next : null });
                      }}
                    />
                    {b.name}
                  </label>
                ))}
              </div>
            </div>
          )}
          <div className="flex gap-2">
            <button className="btn" style={{ minHeight: 44, padding: "0 16px" }} disabled={pending} onClick={() => save(form, () => setForm(null))}>
              Save discount
            </button>
            <button className="rounded-lg border px-3 text-sm" style={{ borderColor: "var(--color-line)", minHeight: 44 }} onClick={() => setForm(null)}>
              Cancel
            </button>
          </div>
        </div>
      )}
      {error && (
        <p className="text-sm" role="alert" style={{ color: "var(--color-bad)" }}>
          {error}
        </p>
      )}
      {note && !error && (
        <p className="text-sm" role="status" style={{ color: "var(--color-ink-2)" }}>
          {note}
        </p>
      )}
    </div>
  );
}
