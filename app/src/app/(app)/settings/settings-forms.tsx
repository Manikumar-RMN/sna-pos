"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { addTable, addTaxGroup, removeTable, saveSettings, setPaymentMethod, setTaxRate, type Result } from "./actions";

type Business = {
  legal_name: string;
  trading_name: string;
  tax_registration_no: string;
  contact_phone: string;
  branch_name: string;
  address_line1: string;
  address_line2: string;
  city: string;
  state_or_region: string;
  postal_code: string;
  phone: string;
  receipt_header: string;
  receipt_footer: string;
  cash_rounding_mode: string;
  auto_print_kot: boolean;
};

function useRunner() {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  function run(fn: () => Promise<Result>, after?: () => void) {
    setMsg(null);
    start(async () => {
      const r = await fn();
      if (r.ok) {
        setMsg({ ok: true, text: r.message ?? "Saved." });
        after?.();
        router.refresh();
      } else setMsg({ ok: false, text: r.error });
    });
  }
  return { pending, msg, run };
}

function Msg({ msg }: { msg: { ok: boolean; text: string } | null }) {
  if (!msg) return null;
  return (
    <p
      className="mt-3 rounded-lg px-3 py-2 text-sm"
      role={msg.ok ? undefined : "alert"}
      style={{ background: msg.ok ? "var(--color-ok-soft)" : "var(--color-bad-soft)", color: msg.ok ? "var(--color-ok)" : "var(--color-bad)" }}
    >
      {msg.text}
    </p>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="mb-1 block text-xs font-semibold">{label}</span>
      {children}
      {hint && (
        <span className="mt-1 block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
          {hint}
        </span>
      )}
    </label>
  );
}

export function BusinessForm({ initial, canEdit }: { initial: Business; canEdit: boolean }) {
  const [v, setV] = useState(initial);
  const { pending, msg, run } = useRunner();
  const set = (k: keyof Business) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
    setV({ ...v, [k]: e.target.type === "checkbox" ? (e.target as HTMLInputElement).checked : e.target.value });

  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Business and receipt</h2>
      <fieldset disabled={!canEdit} className="mt-4 grid gap-3 sm:grid-cols-2">
        <Field label="Registered business name">
          <input className="field" value={v.legal_name} onChange={set("legal_name")} />
        </Field>
        <Field label="Name customers see">
          <input className="field" value={v.trading_name} onChange={set("trading_name")} />
        </Field>
        <Field label="GSTIN" hint="15 characters, e.g. 33AAACA0000A1Z5. Printed on every bill.">
          <input className="field uppercase" value={v.tax_registration_no} onChange={set("tax_registration_no")} maxLength={15} />
        </Field>
        <Field label="Business phone">
          <input className="field" value={v.contact_phone} onChange={set("contact_phone")} />
        </Field>
        <Field label="Branch name">
          <input className="field" value={v.branch_name} onChange={set("branch_name")} />
        </Field>
        <Field label="Branch phone" hint="Printed on the receipt.">
          <input className="field" value={v.phone} onChange={set("phone")} />
        </Field>
        <Field label="Address line 1">
          <input className="field" value={v.address_line1} onChange={set("address_line1")} />
        </Field>
        <Field label="Address line 2">
          <input className="field" value={v.address_line2} onChange={set("address_line2")} />
        </Field>
        <Field label="City">
          <input className="field" value={v.city} onChange={set("city")} />
        </Field>
        <div className="grid grid-cols-2 gap-3">
          <Field label="State">
            <input className="field" value={v.state_or_region} onChange={set("state_or_region")} />
          </Field>
          <Field label="PIN code">
            <input className="field" value={v.postal_code} onChange={set("postal_code")} />
          </Field>
        </div>
        <Field label="Receipt heading" hint="Top line of the bill. Usually the name customers see.">
          <input className="field" value={v.receipt_header} onChange={set("receipt_header")} />
        </Field>
        <Field label="Receipt footer" hint="e.g. Thank you — visit again!">
          <input className="field" value={v.receipt_footer} onChange={set("receipt_footer")} />
        </Field>
        <Field label="Round the bill total" hint="Applied once, to the grand total.">
          <select className="field" value={v.cash_rounding_mode} onChange={set("cash_rounding_mode")}>
            <option value="nearest_1">To the nearest rupee</option>
            <option value="nearest_0_10">To the nearest 10 paise</option>
            <option value="nearest_0_05">To the nearest 5 paise</option>
            <option value="none">No rounding</option>
          </select>
        </Field>
        <label className="flex items-center gap-2 self-center text-sm">
          <input type="checkbox" className="h-5 w-5" checked={v.auto_print_kot} onChange={set("auto_print_kot")} />
          Send every bill to the Kitchen screen
        </label>
      </fieldset>
      {canEdit ? (
        <button className="btn btn-primary mt-5" disabled={pending} onClick={() => run(() => saveSettings(v))}>
          {pending ? "Saving…" : "Save changes"}
        </button>
      ) : (
        <p className="mt-4 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Only an owner can change these.
        </p>
      )}
      <Msg msg={msg} />
    </section>
  );
}

export function TablesForm({ tables, canEdit }: { tables: { id: string; number: string; seats: number; busy: boolean }[]; canEdit: boolean }) {
  const [num, setNum] = useState("");
  const [seats, setSeats] = useState("4");
  const { pending, msg, run } = useRunner();
  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Tables</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Optional. Add your dine-in tables so bills can be linked to them.
      </p>
      <div className="mt-3 flex flex-wrap gap-2">
        {tables.length === 0 && (
          <span className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            No tables yet.
          </span>
        )}
        {tables.map((t) => (
          <span key={t.id} className="flex items-center gap-2 rounded-lg border px-3 py-1.5 text-sm" style={{ borderColor: t.busy ? "var(--color-warn)" : "var(--color-line)" }}>
            <b>T{t.number}</b>
            <span style={{ color: "var(--color-ink-3)" }}>{t.seats} seats</span>
            {canEdit && (
              <button className="text-xs font-semibold" style={{ color: "var(--color-bad)" }} disabled={pending} onClick={() => run(() => removeTable(t.id))} aria-label={`Remove table ${t.number}`}>
                ✕
              </button>
            )}
          </span>
        ))}
      </div>
      {canEdit && (
        <div className="mt-4 flex flex-wrap gap-2">
          <input className="field h-11 w-32 text-sm" placeholder="Table no." value={num} onChange={(e) => setNum(e.target.value)} />
          <input className="field h-11 w-24 text-sm" inputMode="numeric" placeholder="Seats" value={seats} onChange={(e) => setSeats(e.target.value)} />
          <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={pending || !num.trim()} onClick={() => run(() => addTable(num, Number(seats)), () => setNum(""))}>
            Add table
          </button>
        </div>
      )}
      <Msg msg={msg} />
    </section>
  );
}

export function PaymentMethodsForm({ methods, canEdit }: { methods: { id: string; name: string; is_active: boolean }[]; canEdit: boolean }) {
  const { pending, msg, run } = useRunner();
  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Payment methods</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Switch off any method you do not accept. Card and UPI here only record how the customer paid; no gateway is connected yet.
      </p>
      <ul className="mt-3 space-y-2">
        {methods.map((m) => (
          <li key={m.id} className="flex items-center justify-between text-sm">
            <span className="font-medium">{m.name}</span>
            <button
              className="rounded-full px-3 py-1 text-xs font-semibold"
              disabled={!canEdit || pending}
              onClick={() => run(() => setPaymentMethod(m.id, !m.is_active))}
              style={m.is_active ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-ground)", color: "var(--color-ink-3)" }}
            >
              {m.is_active ? "On" : "Off"}
            </button>
          </li>
        ))}
      </ul>
      <Msg msg={msg} />
    </section>
  );
}

export function TaxForm({ groups, canEdit }: { groups: { id: string; name: string; rate: number | null; items: number }[]; canEdit: boolean }) {
  const [edit, setEdit] = useState<Record<string, string>>({});
  const [newName, setNewName] = useState("");
  const [newRate, setNewRate] = useState("");
  const { pending, msg, run } = useRunner();
  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">GST rates</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Each menu item belongs to one tax group. A changed rate applies to new bills from today; bills already issued keep the tax they were charged. Confirm rates with your accountant.
      </p>
      <table className="mt-3 w-full text-sm">
        <thead>
          <tr style={{ color: "var(--color-ink-3)" }}>
            <th className="pb-2 text-left text-xs font-semibold">Group</th>
            <th className="pb-2 text-right text-xs font-semibold">Items</th>
            <th className="pb-2 text-right text-xs font-semibold">Rate</th>
            {canEdit && <th />}
          </tr>
        </thead>
        <tbody>
          {groups.map((g) => (
            <tr key={g.id} style={{ borderTop: "1px solid var(--color-line)" }}>
              <td className="py-2">{g.name}</td>
              <td className="py-2 text-right tabular-nums">{g.items}</td>
              <td className="py-2 text-right tabular-nums">
                {canEdit ? (
                  <input
                    className="field h-9 w-20 text-right text-sm"
                    inputMode="decimal"
                    value={edit[g.id] ?? String(g.rate ?? "")}
                    onChange={(e) => setEdit({ ...edit, [g.id]: e.target.value })}
                  />
                ) : (
                  `${g.rate ?? "—"}%`
                )}
              </td>
              {canEdit && (
                <td className="py-2 pl-2 text-right">
                  <button
                    className="rounded-lg border px-2.5 py-1.5 text-xs font-semibold"
                    style={{ borderColor: "var(--color-line)" }}
                    disabled={pending || edit[g.id] === undefined || Number(edit[g.id]) === g.rate}
                    onClick={() => run(() => setTaxRate(g.id, Number(edit[g.id])), () => setEdit({}))}
                  >
                    Save
                  </button>
                </td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
      {canEdit && (
        <div className="mt-4 flex flex-wrap gap-2">
          <input className="field h-11 w-48 text-sm" placeholder="New group, e.g. Beverages 18%" value={newName} onChange={(e) => setNewName(e.target.value)} />
          <input className="field h-11 w-24 text-sm" inputMode="decimal" placeholder="Rate %" value={newRate} onChange={(e) => setNewRate(e.target.value)} />
          <button
            className="btn border text-sm"
            style={{ borderColor: "var(--color-line)" }}
            disabled={pending || !newName.trim() || newRate === ""}
            onClick={() => run(() => addTaxGroup(newName, Number(newRate)), () => { setNewName(""); setNewRate(""); })}
          >
            Add group
          </button>
        </div>
      )}
      <Msg msg={msg} />
    </section>
  );
}
