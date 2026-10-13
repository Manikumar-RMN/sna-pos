"use client";

import { useState, useTransition } from "react";
import { money } from "@/lib/format";
import { brandSettlement, saveBrand, setCategoryBrand, type BrandInput, type SettlementRow } from "./actions";

export type Brand = { id: string; name: string; legal_name: string | null; gstin: string | null; commission_percent: number; is_active: boolean };
type Category = { id: string; name: string; brand_id: string | null };

const blank: BrandInput = { id: null, name: "", commission: 0, legal_name: "", gstin: "", active: true };

export function Brands({ brands, categories, canEdit }: { brands: Brand[]; categories: Category[]; canEdit: boolean }) {
  const [form, setForm] = useState<BrandInput | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const edit = (b: Brand) =>
    setForm({ id: b.id, name: b.name, commission: Number(b.commission_percent), legal_name: b.legal_name ?? "", gstin: b.gstin ?? "", active: b.is_active });

  return (
    <div className="space-y-4">
      <section className="card p-4">
        <div className="mb-3 flex items-center justify-between gap-2">
          <h2 className="text-sm font-bold">Brands and stalls</h2>
          {canEdit && (
            <button className="btn btn-primary" style={{ minHeight: 40 }} onClick={() => { setError(null); setForm({ ...blank }); }}>
              + Add brand or stall
            </button>
          )}
        </div>
        {brands.length === 0 ? (
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            No brands yet. A single restaurant does not need any. Add them if you run several brands from one kitchen (cloud kitchen) or
            several stalls at one counter (food court).
          </p>
        ) : (
          <table className="w-full text-left text-sm">
            <thead style={{ color: "var(--color-ink-3)" }}>
              <tr>
                <th className="py-1">Name</th>
                <th className="py-1">Commission</th>
                <th className="hidden py-1 sm:table-cell">GSTIN</th>
                <th className="py-1" />
              </tr>
            </thead>
            <tbody>
              {brands.map((b) => (
                <tr key={b.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                  <td className="py-2">
                    {b.name}
                    {!b.is_active && <span className="ml-2 text-xs" style={{ color: "var(--color-ink-3)" }}>(off)</span>}
                  </td>
                  <td className="py-2 tabular-nums">{Number(b.commission_percent)}%</td>
                  <td className="hidden py-2 sm:table-cell">{b.gstin ?? "—"}</td>
                  <td className="py-2 text-right">
                    {canEdit && (
                      <button className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => { setError(null); edit(b); }}>
                        Edit
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {form && (
          <div className="mt-4 grid gap-3 rounded-xl border p-3 sm:grid-cols-2" style={{ borderColor: "var(--color-line)" }}>
            <label className="text-sm font-semibold">
              Name on the menu
              <input className="field mt-1" maxLength={60} value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Burger Barn" autoFocus />
            </label>
            <label className="text-sm font-semibold">
              Commission you keep (%)
              <input className="field mt-1" inputMode="decimal" value={String(form.commission)} onChange={(e) => setForm({ ...form, commission: Number(e.target.value) || 0 })} />
              <span className="mt-1 block text-xs font-normal" style={{ color: "var(--color-ink-3)" }}>Food court: the share you keep from the stall&rsquo;s sales. Your own brands: 0.</span>
            </label>
            <label className="text-sm font-semibold">
              Legal name (optional)
              <input className="field mt-1" maxLength={120} value={form.legal_name} onChange={(e) => setForm({ ...form, legal_name: e.target.value })} />
            </label>
            <label className="text-sm font-semibold">
              GSTIN (optional)
              <input className="field mt-1 uppercase" maxLength={15} value={form.gstin} onChange={(e) => setForm({ ...form, gstin: e.target.value })} />
            </label>
            <label className="flex items-center gap-2 text-sm">
              <input type="checkbox" checked={form.active} onChange={(e) => setForm({ ...form, active: e.target.checked })} /> In use
            </label>
            <div className="flex items-center justify-end gap-2 sm:col-span-2">
              {error && <span className="mr-auto text-xs" role="alert" style={{ color: "var(--color-bad)" }}>{error}</span>}
              <button className="btn" onClick={() => setForm(null)}>Cancel</button>
              <button
                className="btn btn-primary"
                disabled={pending || !form.name.trim()}
                onClick={() =>
                  start(async () => {
                    const r = await saveBrand(form);
                    setError(r.error);
                    if (!r.error) setForm(null);
                  })
                }
              >
                {pending ? "Saving…" : "Save"}
              </button>
            </div>
          </div>
        )}
      </section>

      {brands.length > 0 && <CategoryBrands brands={brands} categories={categories} canEdit={canEdit} />}
    </div>
  );
}

function CategoryBrands({ brands, categories, canEdit }: { brands: Brand[]; categories: Category[]; canEdit: boolean }) {
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Which brand each category belongs to</h2>
      <p className="mb-3 mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Sub-categories go with their main category. A bill line remembers its brand when it is sold, so changing this later does not change past settlements.
      </p>
      <div className="grid gap-2 sm:grid-cols-2">
        {categories.map((c) => (
          <label key={c.id} className="flex items-center justify-between gap-2 rounded-lg border px-3 py-2 text-sm" style={{ borderColor: "var(--color-line)" }}>
            <span className="truncate">{c.name}</span>
            <select
              className="field w-44"
              value={c.brand_id ?? ""}
              disabled={!canEdit || pending}
              onChange={(e) =>
                start(async () => {
                  const r = await setCategoryBrand(c.id, e.target.value || null);
                  setError(r.error);
                })
              }
            >
              <option value="">— no brand —</option>
              {brands.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </select>
          </label>
        ))}
      </div>
      {error && <p className="mt-2 text-xs" role="alert" style={{ color: "var(--color-bad)" }}>{error}</p>}
    </section>
  );
}

/** What each brand or stall sold and is owed. */
export function Settlement({ currency, today }: { currency: string; today: string }) {
  const [from, setFrom] = useState(today.slice(0, 8) + "01");
  const [to, setTo] = useState(today);
  const [rows, setRows] = useState<SettlementRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const m = (n: number) => money(n, currency);
  const total = (k: keyof SettlementRow) => (rows ?? []).reduce((s, r) => s + Number(r[k] ?? 0), 0);
  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold">Settlement per brand or stall</h2>
      <div className="mt-2 flex flex-wrap items-end gap-2">
        <label className="text-xs font-semibold">
          From <input type="date" className="field mt-1" value={from} onChange={(e) => setFrom(e.target.value)} />
        </label>
        <label className="text-xs font-semibold">
          To <input type="date" className="field mt-1" value={to} onChange={(e) => setTo(e.target.value)} />
        </label>
        <button
          className="btn btn-primary"
          disabled={pending}
          onClick={() =>
            start(async () => {
              const r = await brandSettlement(from, to);
              setError(r.error);
              setRows(r.error ? null : r.rows);
            })
          }
        >
          {pending ? "Working…" : "Show"}
        </button>
      </div>
      {error && <p className="mt-2 text-xs" role="alert" style={{ color: "var(--color-bad)" }}>{error}</p>}
      {rows && (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full text-left text-sm tabular-nums">
            <thead style={{ color: "var(--color-ink-3)" }}>
              <tr>
                <th className="py-1">Brand / stall</th>
                <th className="py-1 text-right">Bills</th>
                <th className="py-1 text-right">Sales</th>
                <th className="py-1 text-right">Tax</th>
                <th className="py-1 text-right">Commission</th>
                <th className="py-1 text-right">Payable</th>
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 && (
                <tr><td colSpan={6} className="py-2" style={{ color: "var(--color-ink-3)" }}>No sales in these dates.</td></tr>
              )}
              {rows.map((r) => (
                <tr key={r.brand_id ?? "none"} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                  <td className="py-2">{r.brand}</td>
                  <td className="py-2 text-right">{r.bills}</td>
                  <td className="py-2 text-right">{m(r.sales)}</td>
                  <td className="py-2 text-right">{m(r.tax)}</td>
                  <td className="py-2 text-right">{m(r.commission)} <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>({Number(r.commission_percent)}%)</span></td>
                  <td className="py-2 text-right font-semibold">{m(r.payable)}</td>
                </tr>
              ))}
            </tbody>
            {rows.length > 1 && (
              <tfoot>
                <tr className="border-t font-semibold" style={{ borderColor: "var(--color-line)" }}>
                  <td className="py-2">Total</td>
                  <td className="py-2 text-right" />
                  <td className="py-2 text-right">{m(total("sales"))}</td>
                  <td className="py-2 text-right">{m(total("tax"))}</td>
                  <td className="py-2 text-right">{m(total("commission"))}</td>
                  <td className="py-2 text-right">{m(total("payable"))}</td>
                </tr>
              </tfoot>
            )}
          </table>
          <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Sales are after discounts and before tax. Payable = sales + tax − commission. Complimentary bills, voided bills and the packing charge are left out.
          </p>
        </div>
      )}
    </section>
  );
}
