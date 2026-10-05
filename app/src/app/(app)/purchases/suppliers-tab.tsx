"use client";

import { useState } from "react";
import { money } from "@/lib/format";
import { saveSupplier } from "./actions";
import type { SupplierRow } from "./helpers";
import { Badge, Field, Msg, lineStyle, rowBtn, useRun } from "./ui";

type Draft = {
  id: string | null;
  name: string;
  contactPerson: string;
  phone: string;
  email: string;
  taxNo: string;
  address: string;
  paymentDays: string;
  notes: string;
  isActive: boolean;
};

const NEW: Draft = { id: null, name: "", contactPerson: "", phone: "", email: "", taxNo: "", address: "", paymentDays: "0", notes: "", isActive: true };

export function SuppliersTab({
  suppliers,
  owed,
  currency,
  taxLabel,
}: {
  suppliers: SupplierRow[];
  /** What is still owed to each supplier at this outlet, by supplier id. */
  owed: Record<string, number>;
  currency: string;
  /** The country's name for a tax number, e.g. "GSTIN". */
  taxLabel: string;
}) {
  const { pending, msg, setMsg, run } = useRun();
  // With no suppliers yet, the form is already open: there is nothing else to do here.
  const [edit, setEdit] = useState<Draft | null>(suppliers.length === 0 ? { ...NEW } : null);
  const upd = (patch: Partial<Draft>) => setEdit((e) => (e ? { ...e, ...patch } : e));

  function open(s: SupplierRow) {
    setMsg(null);
    setEdit({
      id: s.id,
      name: s.name,
      contactPerson: s.contact_person ?? "",
      phone: s.phone ?? "",
      email: s.email ?? "",
      taxNo: s.tax_no ?? "",
      address: s.address ?? "",
      paymentDays: String(s.payment_days),
      notes: s.notes ?? "",
      isActive: s.is_active,
    });
  }

  function save() {
    if (!edit) return;
    if (!edit.name.trim()) return setMsg({ ok: false, text: "Enter the supplier's name." });
    const days = edit.paymentDays.trim() === "" ? 0 : Number(edit.paymentDays);
    if (!Number.isInteger(days) || days < 0 || days > 365) return setMsg({ ok: false, text: "Pays in (days) must be a whole number from 0 to 365." });
    run(
      () =>
        saveSupplier(edit.id, {
          name: edit.name,
          contactPerson: edit.contactPerson,
          phone: edit.phone,
          email: edit.email,
          taxNo: edit.taxNo,
          address: edit.address,
          paymentDays: days,
          notes: edit.notes,
          isActive: edit.isActive,
        }),
      () => setEdit(null),
    );
  }

  return (
    <div className="space-y-4">
      {!edit && <Msg msg={msg} />}

      {edit ? (
        <section className="card p-4">
          <h2 className="text-sm font-bold">{edit.id ? "Edit supplier" : "New supplier"}</h2>
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <Field label="Supplier name">
              <input className="field h-10 text-sm" placeholder="e.g. Sri Murugan Vegetables" value={edit.name} onChange={(e) => upd({ name: e.target.value })} maxLength={80} disabled={pending} />
            </Field>
            <Field label="Contact person" hint="(optional)">
              <input className="field h-10 text-sm" value={edit.contactPerson} onChange={(e) => upd({ contactPerson: e.target.value })} maxLength={80} disabled={pending} />
            </Field>
            <Field label="Phone" hint="(optional)">
              <input className="field h-10 text-sm" type="tel" inputMode="tel" value={edit.phone} onChange={(e) => upd({ phone: e.target.value })} maxLength={30} disabled={pending} />
            </Field>
            <Field label="Email" hint="(optional)">
              <input className="field h-10 text-sm" type="email" inputMode="email" value={edit.email} onChange={(e) => upd({ email: e.target.value })} maxLength={120} disabled={pending} />
            </Field>
            <Field label={taxLabel} hint="(optional)">
              <input className="field h-10 text-sm uppercase" value={edit.taxNo} onChange={(e) => upd({ taxNo: e.target.value })} maxLength={30} disabled={pending} />
            </Field>
            <Field label="Pays in (days)" hint="— 0 means you pay on delivery">
              <input className="field h-10 text-sm" inputMode="numeric" value={edit.paymentDays} onChange={(e) => upd({ paymentDays: e.target.value })} maxLength={3} disabled={pending} />
            </Field>
            <Field label="Address" hint="(optional)" className="sm:col-span-2">
              <input className="field h-10 text-sm" value={edit.address} onChange={(e) => upd({ address: e.target.value })} maxLength={300} disabled={pending} />
            </Field>
            <Field label="Notes" hint="(optional)" className="sm:col-span-2">
              <input className="field h-10 text-sm" placeholder="e.g. delivers before 7 am, closed Sundays" value={edit.notes} onChange={(e) => upd({ notes: e.target.value })} maxLength={300} disabled={pending} />
            </Field>
          </div>
          <label className="mt-3 flex min-h-10 items-center gap-2 text-sm">
            <input type="checkbox" className="h-5 w-5" checked={edit.isActive} onChange={(e) => upd({ isActive: e.target.checked })} disabled={pending} />
            Active (untick to hide this supplier from new orders and deliveries)
          </label>
          <div className="mt-3">
            <Msg msg={msg} />
          </div>
          <div className="mt-3 flex flex-wrap gap-2">
            <button
              type="button"
              className="btn border px-4 text-sm"
              style={lineStyle}
              onClick={() => {
                setEdit(null);
                setMsg(null);
              }}
              disabled={pending}
            >
              Cancel
            </button>
            <button type="button" className="btn btn-primary px-4 text-sm" onClick={save} disabled={pending}>
              {pending ? "Saving…" : "Save supplier"}
            </button>
          </div>
        </section>
      ) : (
        <button
          type="button"
          className="btn btn-primary px-4 text-sm"
          onClick={() => {
            setMsg(null);
            setEdit({ ...NEW });
          }}
        >
          + Add supplier
        </button>
      )}

      <div className="card overflow-x-auto">
        <table className="w-full text-sm">
          <thead>
            <tr style={{ color: "var(--color-ink-3)" }}>
              <th className="px-3 py-2 text-left text-xs font-semibold">Supplier</th>
              <th className="px-3 py-2 text-left text-xs font-semibold">Phone</th>
              <th className="px-3 py-2 text-left text-xs font-semibold">Pays in</th>
              <th className="px-3 py-2 text-right text-xs font-semibold">You owe</th>
              <th className="px-3 py-2" />
            </tr>
          </thead>
          <tbody>
            {suppliers.length === 0 && (
              <tr>
                <td colSpan={5} className="px-3 py-6 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                  No suppliers yet. Add the people you buy from, then you can order and receive goods.
                </td>
              </tr>
            )}
            {suppliers.map((s) => {
              const due = owed[s.id] ?? 0;
              return (
                <tr key={s.id} style={{ borderTop: "1px solid var(--color-line)" }}>
                  <td className="px-3 py-2">
                    <span className="font-semibold">{s.name}</span>{" "}
                    {!s.is_active && <Badge label="Not active" bg="var(--color-ground)" fg="var(--color-ink-2)" />}
                    {s.contact_person && (
                      <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                        {s.contact_person}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2 whitespace-nowrap">{s.phone ?? "—"}</td>
                  <td className="px-3 py-2 whitespace-nowrap">{s.payment_days > 0 ? `${s.payment_days} day${s.payment_days === 1 ? "" : "s"}` : "On delivery"}</td>
                  <td className="px-3 py-2 text-right tabular-nums" style={{ color: due > 0 ? "var(--color-bad)" : "var(--color-ink-3)", fontWeight: due > 0 ? 700 : 400 }}>
                    {due > 0 ? money(due, currency) : "—"}
                  </td>
                  <td className="px-3 py-2 text-right">
                    <button type="button" className={rowBtn} style={lineStyle} onClick={() => open(s)} disabled={pending} aria-label={`Edit ${s.name}`}>
                      Edit
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}
