"use client";

import { useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  addTable,
  addTables,
  removeTable,
  savePackingCharge,
  saveSettings,
  saveTaxGroup,
  setPaymentMethod,
  setPricesIncludeTax,
  type Result,
  type TaxComponent,
  savePaymentOptions,
  setUpThisTabletAsCounter,
  removeCounter,
  clearCounterLock,
} from "./actions";
import { ConfirmButton } from "./confirm-button";

import { useTz } from "../tz";
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
      role={msg.ok ? "status" : "alert"}
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

function Toggle({ checked, onChange, label, hint, disabled }: { checked: boolean; onChange: (v: boolean) => void; label: string; hint?: string; disabled?: boolean }) {
  return (
    <label className="flex items-start gap-3 text-sm">
      <input type="checkbox" className="mt-0.5 h-5 w-5 shrink-0" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span>
        {label}
        {hint && (
          <span className="block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            {hint}
          </span>
        )}
      </span>
    </label>
  );
}

/* ------------------------------------------------------------------ business */

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
  auto_print_kot: boolean;
  /** India only. */
  fssai_no?: string;
  sac_code?: string;
};

export function BusinessForm({ initial, canEdit, taxIdLabel, taxIdHint }: { initial: Business; canEdit: boolean; taxIdLabel: string; taxIdHint: string }) {
  const [v, setV] = useState(initial);
  const { pending, msg, run } = useRunner();
  const set = (k: keyof Business) => (e: React.ChangeEvent<HTMLInputElement>) => setV({ ...v, [k]: e.target.value });

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
        <Field label={taxIdLabel} hint={taxIdHint}>
          <input className="field uppercase" value={v.tax_registration_no} onChange={set("tax_registration_no")} maxLength={30} />
        </Field>
        <Field label="Business phone">
          <input className="field" value={v.contact_phone} onChange={set("contact_phone")} />
        </Field>
        {v.fssai_no !== undefined && (
          <Field label="FSSAI licence number" hint="14 digits. Printed on every bill, as FSSAI requires.">
            <input className="field" inputMode="numeric" maxLength={14} value={v.fssai_no} onChange={set("fssai_no")} />
          </Field>
        )}
        {v.sac_code !== undefined && (
          <Field label="SAC code on bills" hint="996331 is restaurant service. Change only if your accountant says so.">
            <input className="field" inputMode="numeric" maxLength={8} value={v.sac_code} onChange={set("sac_code")} />
          </Field>
        )}
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
          <Field label="State / region">
            <input className="field" value={v.state_or_region} onChange={set("state_or_region")} />
          </Field>
          <Field label="Postcode">
            <input className="field" value={v.postal_code} onChange={set("postal_code")} />
          </Field>
        </div>
        <Field label="Receipt heading" hint="Top line of the bill. Usually the name customers see.">
          <input className="field" value={v.receipt_header} onChange={set("receipt_header")} />
        </Field>
        <Field label="Receipt footer" hint="e.g. Thank you — visit again!">
          <input className="field" value={v.receipt_footer} onChange={set("receipt_footer")} />
        </Field>
        <div className="sm:col-span-2">
          <Toggle checked={v.auto_print_kot} onChange={(x) => setV({ ...v, auto_print_kot: x })} label="Send every bill to the Kitchen screen" />
        </div>
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

/* ------------------------------------------------ service charge + rounding */

type Charges = {
  service_charge_percent: number;
  service_charge_label: string;
  service_charge_taxable: boolean;
  service_charge_default_on: boolean;
  cash_rounding_mode: string;
  rounding_cash_only: boolean;
};

export function ChargesForm({ initial, canEdit, taxName, serviceChargeHint }: { initial: Charges; canEdit: boolean; taxName: string; serviceChargeHint: string }) {
  const [v, setV] = useState(initial);
  const [pct, setPct] = useState(String(initial.service_charge_percent));
  const { pending, msg, run } = useRunner();

  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Service charge and rounding</h2>
      <fieldset disabled={!canEdit} className="mt-4 space-y-4">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Service charge %" hint="0 = no service charge.">
            <input className="field" inputMode="decimal" value={pct} onChange={(e) => setPct(e.target.value)} />
          </Field>
          <Field label="Name on the bill">
            <input className="field" value={v.service_charge_label} onChange={(e) => setV({ ...v, service_charge_label: e.target.value })} />
          </Field>
        </div>
        <Toggle
          checked={v.service_charge_default_on}
          onChange={(x) => setV({ ...v, service_charge_default_on: x })}
          label="Add the service charge to every bill by default"
          hint={`The cashier can still switch it off on any bill. ${serviceChargeHint}`}
        />
        <Toggle
          checked={v.service_charge_taxable}
          onChange={(x) => setV({ ...v, service_charge_taxable: x })}
          label={`Charge ${taxName} on the service charge`}
          hint="Normal in Singapore, Malaysia, Thailand, Indonesia, the Philippines and the UAE. Not in India."
        />
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Round the bill" hint="Applied once, to the total.">
            <select className="field" value={v.cash_rounding_mode} onChange={(e) => setV({ ...v, cash_rounding_mode: e.target.value })}>
              <option value="none">No rounding</option>
              <option value="nearest_1">To the nearest whole unit (₹1, Rp1)</option>
              <option value="nearest_0_10">To the nearest 0.10</option>
              <option value="nearest_0_05">To the nearest 0.05 (e.g. 5 sen)</option>
            </select>
          </Field>
          <div className="self-end pb-2">
            <Toggle
              checked={v.rounding_cash_only}
              onChange={(x) => setV({ ...v, rounding_cash_only: x })}
              label="Only when paying by cash"
              hint="Malaysia's rule: cards and QR pay the exact amount."
            />
          </div>
        </div>
      </fieldset>
      {canEdit && (
        <button
          className="btn btn-primary mt-5"
          disabled={pending}
          onClick={() => run(() => saveSettings({ ...v, service_charge_percent: Number(pct) || 0 }))}
        >
          {pending ? "Saving…" : "Save changes"}
        </button>
      )}
      <Msg msg={msg} />
    </section>
  );
}

/* ----------------------------------------------- packing charge + tokens */

type Packing = {
  /** 0 = switched off. */
  amount: number;
  per: "bill" | "item";
  /** "" = not chosen yet. */
  taxGroupId: string;
  takeaway: boolean;
  delivery: boolean;
};

export function PackingForm({
  initial,
  taxGroups,
  canEdit,
  currency,
  taxName,
  severalOutlets,
  lost,
}: {
  initial: Packing;
  taxGroups: { id: string; name: string }[];
  canEdit: boolean;
  currency: string;
  taxName: string;
  severalOutlets: boolean;
  /** The charge is switched on here, but its menu item was removed or switched off on the Menu screen. */
  lost: boolean;
}) {
  const [v, setV] = useState(initial);
  const [amount, setAmount] = useState(initial.amount > 0 ? String(initial.amount) : "");
  const { pending, msg, run } = useRunner();
  const typed = amount.trim();
  const value = typed === "" ? 0 : Number(typed);

  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Packing charge</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Added automatically to takeaway and delivery bills. The cashier can untick it on any bill. It appears in the menu as
        &ldquo;Packing charge&rdquo; under &ldquo;Charges&rdquo;.
      </p>
      {lost && (
        <p className="mt-3 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}>
          The &ldquo;Packing charge&rdquo; menu item was removed or switched off, so bills are not getting it. Enter the amount and save here to put it back.
        </p>
      )}
      <fieldset disabled={!canEdit} className="mt-4 space-y-4">
        <div className="grid gap-3 sm:grid-cols-3">
          <Field label={`Amount (${currency})`} hint="Empty or 0 = no packing charge.">
            <input className="field" inputMode="decimal" placeholder="0" value={amount} onChange={(e) => setAmount(e.target.value)} />
          </Field>
          <Field label="Charge it">
            <select className="field" value={v.per} onChange={(e) => setV({ ...v, per: e.target.value === "item" ? "item" : "bill" })}>
              <option value="bill">Once per bill</option>
              <option value="item">For every item</option>
            </select>
          </Field>
          <Field label={`${taxName} on it`}>
            <select className="field" value={v.taxGroupId} onChange={(e) => setV({ ...v, taxGroupId: e.target.value })}>
              <option value="">Choose…</option>
              {taxGroups.map((g) => (
                <option key={g.id} value={g.id}>
                  {g.name}
                </option>
              ))}
            </select>
          </Field>
        </div>
        <div className="flex flex-wrap gap-x-8 gap-y-3">
          <Toggle checked={v.takeaway} onChange={(x) => setV({ ...v, takeaway: x })} label="Takeaway bills" />
          <Toggle checked={v.delivery} onChange={(x) => setV({ ...v, delivery: x })} label="Delivery bills" />
        </div>
      </fieldset>
      {severalOutlets && (
        <p className="mt-3 text-xs" style={{ color: "var(--color-ink-3)" }}>
          You have several outlets: each outlet sets its own amount here and chooses for itself whether to use the packing charge.
          The {taxName} on it is the same at every outlet.
        </p>
      )}
      {canEdit && (
        <button
          className="btn btn-primary mt-5"
          disabled={pending}
          onClick={() => run(() => savePackingCharge({ ...v, amount: value }), () => value === 0 && setAmount(""))}
        >
          {pending ? "Saving…" : "Save changes"}
        </button>
      )}
      <Msg msg={msg} />
    </section>
  );
}

const TOKEN_CHOICES: { key: "off" | "takeaway" | "all"; label: string; hint: string }[] = [
  { key: "off", label: "Off", hint: "No token numbers." },
  { key: "takeaway", label: "Takeaway and delivery", hint: "Dine-in bills go by table." },
  { key: "all", label: "Every bill", hint: "Dine-in bills too." },
];

export function TokensForm({ initial, canEdit }: { initial: string; canEdit: boolean }) {
  const [v, setV] = useState<"off" | "takeaway" | "all">(initial === "takeaway" || initial === "all" ? initial : "off");
  const { pending, msg, run } = useRunner();

  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Token numbers</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Tokens start again from 1 every business day and print large on the bill and the kitchen ticket.
      </p>
      <fieldset disabled={!canEdit} className="mt-4 grid gap-2 sm:grid-cols-3">
        <legend className="sr-only">Give a token number to</legend>
        {TOKEN_CHOICES.map((t) => {
          const on = v === t.key;
          return (
            <label
              key={t.key}
              className="flex min-h-14 items-center gap-3 rounded-2xl border px-3.5 py-2 text-sm"
              style={on ? { borderColor: "var(--color-brand)", background: "var(--color-brand-soft)" } : { borderColor: "var(--color-line)" }}
            >
              <input type="radio" name="token_numbers" className="h-5 w-5 shrink-0" checked={on} onChange={() => setV(t.key)} />
              <span>
                <span className="block font-semibold">{t.label}</span>
                <span className="block text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                  {t.hint}
                </span>
              </span>
            </label>
          );
        })}
      </fieldset>
      {canEdit && (
        <button className="btn btn-primary mt-5" disabled={pending} onClick={() => run(() => saveSettings({ token_numbers: v }))}>
          {pending ? "Saving…" : "Save changes"}
        </button>
      )}
      <Msg msg={msg} />
    </section>
  );
}

/* ---------------------------------------------------------------------- tax */

export type TaxGroupView = { id: string; name: string; items: number; comps: TaxComponent[] };

function describe(comps: TaxComponent[], isIndia: boolean) {
  const main = comps.filter((c) => c.applies_when !== "inter_region");
  if (main.length === 0) return "No tax";
  const text = main.map((c, i) => `${i > 0 && c.compound ? "then " : ""}${c.name} ${c.rate}%`).join(" + ");
  const other = comps.filter((c) => c.applies_when === "inter_region");
  return isIndia && other.length ? `${text} · other state: ${other.map((c) => `${c.name} ${c.rate}%`).join(" + ")}` : text;
}

export function TaxForm({
  groups,
  canEdit,
  isIndia,
  taxName,
  pricesInclude,
}: {
  groups: TaxGroupView[];
  canEdit: boolean;
  isIndia: boolean;
  taxName: string;
  pricesInclude: boolean;
}) {
  const [editing, setEditing] = useState<string | "new" | null>(null);
  const { pending, msg, run } = useRunner();

  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">{taxName} and other taxes</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Every menu item belongs to one tax group. Changes apply to new bills from today; bills already issued keep the tax they were charged.
        Confirm rates with your accountant.
      </p>

      <div className="mt-4 rounded-lg border p-3" style={{ borderColor: "var(--color-line)" }}>
        <Toggle
          checked={pricesInclude}
          disabled={!canEdit || pending}
          onChange={(x) => run(() => setPricesIncludeTax(x))}
          label={`My menu prices already include ${taxName}`}
          hint={pricesInclude ? `${taxName} is taken out of the menu price and shown on the bill.` : `${taxName} is added on top of the menu price.`}
        />
      </div>

      <ul className="mt-4 space-y-2">
        {groups.map((g) =>
          editing === g.id ? (
            <li key={g.id}>
              <GroupEditor
                initialName={g.name}
                initialComps={g.comps}
                isIndia={isIndia}
                pending={pending}
                onCancel={() => setEditing(null)}
                onSave={(name, comps) => run(() => saveTaxGroup(g.id, name, comps), () => setEditing(null))}
              />
            </li>
          ) : (
            <li key={g.id} className="flex items-center justify-between gap-3 rounded-lg border px-3 py-2" style={{ borderColor: "var(--color-line)" }}>
              <div className="min-w-0">
                <div className="text-sm font-semibold">{g.name}</div>
                <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>
                  {describe(g.comps, isIndia)} · {g.items} item{g.items === 1 ? "" : "s"}
                </div>
              </div>
              {canEdit && (
                <button className="shrink-0 rounded-lg border px-2.5 py-1.5 text-xs font-semibold" style={{ borderColor: "var(--color-line)" }} onClick={() => setEditing(g.id)}>
                  Edit
                </button>
              )}
            </li>
          ),
        )}
      </ul>

      {canEdit &&
        (editing === "new" ? (
          <div className="mt-2">
            <GroupEditor
              initialName=""
              initialComps={[{ name: taxName, rate: 0, compound: false, applies_when: "always" }]}
              isIndia={isIndia}
              pending={pending}
              onCancel={() => setEditing(null)}
              onSave={(name, comps) => run(() => saveTaxGroup(null, name, comps), () => setEditing(null))}
            />
          </div>
        ) : (
          <button className="btn mt-3 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={() => setEditing("new")}>
            + Add a tax group
          </button>
        ))}
      <Msg msg={msg} />
    </section>
  );
}

function GroupEditor({
  initialName,
  initialComps,
  isIndia,
  pending,
  onCancel,
  onSave,
}: {
  initialName: string;
  initialComps: TaxComponent[];
  isIndia: boolean;
  pending: boolean;
  onCancel: () => void;
  onSave: (name: string, comps: TaxComponent[]) => void;
}) {
  const [name, setName] = useState(initialName);
  const [rows, setRows] = useState(initialComps.map((c) => ({ ...c, rate: String(c.rate) })));
  const update = (i: number, patch: Partial<(typeof rows)[number]>) => setRows(rows.map((r, j) => (j === i ? { ...r, ...patch } : r)));
  const valid = name.trim() && rows.every((r) => r.name.trim() && r.rate !== "" && Number(r.rate) >= 0 && Number(r.rate) <= 40);

  return (
    <div className="space-y-3 rounded-lg border p-3" style={{ borderColor: "var(--color-brand)" }}>
      <Field label="Group name">
        <input className="field h-10 text-sm" value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Beverages 18%" />
      </Field>
      <div className="space-y-2">
        {rows.map((r, i) => (
          <div key={i} className="rounded-md p-2" style={{ background: "var(--color-ground)" }}>
            <div className="flex gap-2">
              <input className="field h-10 flex-1 text-sm" aria-label="Tax name" placeholder="Tax name" value={r.name} onChange={(e) => update(i, { name: e.target.value })} />
              <div className="flex items-center gap-1">
                <input className="field h-10 w-20 text-right text-sm" aria-label="Rate percent" inputMode="decimal" value={r.rate} onChange={(e) => update(i, { rate: e.target.value })} />
                <span className="text-sm">%</span>
              </div>
              <button className="px-2 text-sm font-semibold" style={{ color: "var(--color-bad)" }} aria-label="Remove this tax" onClick={() => setRows(rows.filter((_, j) => j !== i))}>
                ✕
              </button>
            </div>
            <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs">
              {i > 0 && (
                <label className="flex items-center gap-1.5">
                  <input type="checkbox" checked={r.compound} onChange={(e) => update(i, { compound: e.target.checked })} />
                  Charged on top of the taxes above (tax on tax)
                </label>
              )}
              {isIndia && (
                <label className="flex items-center gap-1.5">
                  Applies
                  <select
                    className="rounded border px-1 py-0.5"
                    value={r.applies_when}
                    onChange={(e) => update(i, { applies_when: e.target.value as TaxComponent["applies_when"] })}
                  >
                    <option value="always">always</option>
                    <option value="intra_region">same state (CGST/SGST)</option>
                    <option value="inter_region">other state (IGST)</option>
                  </select>
                </label>
              )}
            </div>
          </div>
        ))}
      </div>
      <button
        className="text-xs font-semibold"
        style={{ color: "var(--color-brand)" }}
        disabled={rows.length >= 6}
        onClick={() => setRows([...rows, { name: "", rate: "0", compound: false, applies_when: "always" }])}
      >
        + Add another tax to this group
      </button>
      <div className="flex gap-2">
        <button className="btn flex-1 border text-sm" style={{ borderColor: "var(--color-line)" }} onClick={onCancel}>
          Cancel
        </button>
        <button
          className="btn btn-primary flex-1 text-sm"
          disabled={pending || !valid}
          onClick={() =>
            onSave(
              name.trim(),
              rows.map((r, i) => ({ name: r.name.trim(), rate: Number(r.rate), compound: i > 0 && r.compound, applies_when: r.applies_when })),
            )
          }
        >
          {pending ? "Saving…" : "Save"}
        </button>
      </div>
    </div>
  );
}

/* ------------------------------------------------------ tables + payments */

export function TablesForm({ tables, canEdit }: { tables: { id: string; number: string; seats: number; busy: boolean }[]; canEdit: boolean }) {
  const [num, setNum] = useState("");
  const [seats, setSeats] = useState("4");
  const [many, setMany] = useState(false);
  const [pre, setPre] = useState("");
  const [from, setFrom] = useState("1");
  const [to, setTo] = useState("10");
  const [manySeats, setManySeats] = useState("4");
  const { pending, msg, run } = useRunner();
  const fromN = Number(from);
  const toN = Number(to);
  const count = Number.isInteger(fromN) && Number.isInteger(toN) && toN >= fromN ? toN - fromN + 1 : 0;
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
          <span key={t.id} className="flex max-w-full flex-wrap items-center gap-2 rounded-lg border px-3 py-1.5 text-sm" style={{ borderColor: t.busy ? "var(--color-warn)" : "var(--color-line)" }}>
            <b>{/^[0-9]+$/.test(t.number) ? `T${t.number}` : t.number}</b>
            <span style={{ color: "var(--color-ink-3)" }}>{t.seats} seats</span>
            {canEdit && (
              <ConfirmButton
                className="text-xs font-semibold"
                question={`Remove table ${t.number}?`}
                ariaLabel={`Remove table ${t.number}`}
                disabled={pending}
                onConfirm={() => run(() => removeTable(t.id))}
              >
                ✕
              </ConfirmButton>
            )}
          </span>
        ))}
      </div>
      {canEdit && (
        <div className="mt-4 flex flex-wrap gap-2">
          <input className="field h-11 w-32 text-sm" placeholder="Table no." value={num} onChange={(e) => setNum(e.target.value)} />
          <input className="field h-11 w-24 text-sm" inputMode="numeric" placeholder="Seats" aria-label="Seats" value={seats} onChange={(e) => setSeats(e.target.value)} />
          <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} disabled={pending || !num.trim()} onClick={() => run(() => addTable(num, Number(seats)), () => setNum(""))}>
            Add table
          </button>
          <button className="btn border text-sm" style={{ borderColor: "var(--color-line)" }} aria-expanded={many} onClick={() => setMany((v) => !v)}>
            Add many tables
          </button>
        </div>
      )}
      {canEdit && many && (
        <div className="mt-3 rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
          <div className="text-sm font-bold">Add many tables at once</div>
          <p className="mt-0.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
            For example from 1 to 20 makes tables 1 to 20. Letters in front are optional: &ldquo;A&rdquo; from 1 to 10 makes A1 to A10 (for a
            second hall or the AC section). Tables that already exist are left as they are.
          </p>
          <div className="mt-2 flex flex-wrap items-end gap-2">
            <label className="text-xs font-semibold">
              Letters in front
              <input className="field mt-1 h-11 w-24 text-sm uppercase" maxLength={6} placeholder="None" value={pre} onChange={(e) => setPre(e.target.value.toUpperCase())} />
            </label>
            <label className="text-xs font-semibold">
              From
              <input className="field mt-1 h-11 w-20 text-sm" inputMode="numeric" value={from} onChange={(e) => setFrom(e.target.value.replace(/[^0-9]/g, ""))} />
            </label>
            <label className="text-xs font-semibold">
              To
              <input className="field mt-1 h-11 w-20 text-sm" inputMode="numeric" value={to} onChange={(e) => setTo(e.target.value.replace(/[^0-9]/g, ""))} />
            </label>
            <label className="text-xs font-semibold">
              Seats each
              <input className="field mt-1 h-11 w-20 text-sm" inputMode="numeric" value={manySeats} onChange={(e) => setManySeats(e.target.value.replace(/[^0-9]/g, ""))} />
            </label>
            <button
              className="btn btn-primary text-sm"
              disabled={pending || count === 0 || count > 100}
              onClick={() => run(() => addTables(pre, fromN, toN, Number(manySeats)), () => setMany(false))}
            >
              {count > 100 ? "Up to 100 at a time" : count > 0 ? `Add ${count} ${count === 1 ? "table" : "tables"}` : "Add tables"}
            </button>
          </div>
          {count > 0 && count <= 100 && (
            <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
              Tables {pre.trim()}
              {fromN} to {pre.trim()}
              {toN}
            </p>
          )}
        </div>
      )}
      <Msg msg={msg} />
    </section>
  );
}

type MethodView = { id: string; name: string; kind: string; is_active: boolean; ask_reference: boolean; upi_id: string | null; collection_mode: string };

export function PaymentMethodsForm({ methods, canEdit }: { methods: MethodView[]; canEdit: boolean }) {
  const { pending, msg, run } = useRunner();
  const [open, setOpen] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [newName, setNewName] = useState("");
  const [newKind, setNewKind] = useState("wallet");
  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Payment methods</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        <b>Settlement mode:</b> the customer pays on your own card machine, UPI or wallet, and SNA POS records how each bill was
        paid. Reports → Settlement shows what to expect from each. A payment gateway can be connected later.
      </p>
      <ul className="mt-3 divide-y" style={{ borderColor: "var(--color-line)" }}>
        {methods.map((pm) => (
          <li key={pm.id} className="py-2 text-sm">
            <div className="flex items-center justify-between gap-2">
            <button className="min-w-0 flex-1 text-left" onClick={() => setOpen(open === pm.id ? null : pm.id)} aria-expanded={open === pm.id}>
              <span className="font-medium">{pm.name}</span>
              <span className="ml-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                {pm.collection_mode === "gateway" ? "Gateway" : "Record only"}
                {pm.ask_reference ? " · asks for reference" : ""}
                {pm.upi_id ? ` · ${pm.upi_id}` : ""}
              </span>
            </button>
            <button
              className="rounded-full px-3 py-1 text-xs font-semibold"
              disabled={!canEdit || pending}
              aria-pressed={pm.is_active}
              onClick={() => run(() => setPaymentMethod(pm.id, !pm.is_active))}
              style={pm.is_active ? { background: "var(--color-ok-soft)", color: "var(--color-ok)" } : { background: "var(--color-ground)", color: "var(--color-ink-3)" }}
            >
              {pm.is_active ? "On" : "Off"}
            </button>
            </div>
            {open === pm.id && (
              <MethodOptions method={pm} canEdit={canEdit} pending={pending} onSave={(ask, upi, name, kind) => run(() => savePaymentOptions(pm.id, ask, upi, name, kind))} />
            )}
          </li>
        ))}
      </ul>
      {canEdit &&
        (adding ? (
          <div className="mt-3 space-y-2 rounded-lg p-3" style={{ background: "var(--color-ground)" }}>
            <Field label="Name the customer sees on the bill" hint="e.g. Paytm, GCash, GrabPay, Swiggy Dineout, Company account">
              <input className="field h-10 text-sm" value={newName} maxLength={30} onChange={(e) => setNewName(e.target.value)} placeholder="Paytm" />
            </Field>
            <Field label="Kind">
              <select className="field h-10 text-sm" value={newKind} onChange={(e) => setNewKind(e.target.value)}>
                {PAYMENT_KINDS.map(([k, label]) => (
                  <option key={k} value={k}>
                    {label}
                  </option>
                ))}
              </select>
            </Field>
            <div className="flex gap-2">
              <button className="btn h-9 border px-4 text-xs" style={{ borderColor: "var(--color-line)" }} onClick={() => setAdding(false)}>
                Cancel
              </button>
              <button
                className="btn btn-primary h-9 px-4 text-xs"
                disabled={pending || !newName.trim()}
                onClick={() =>
                  run(
                    () => savePaymentOptions(null, newKind !== "cash", "", newName, newKind),
                    () => {
                      setAdding(false);
                      setNewName("");
                    },
                  )
                }
              >
                Add payment method
              </button>
            </div>
          </div>
        ) : (
          <button className="btn mt-3 h-9 border px-4 text-xs" style={{ borderColor: "var(--color-line)" }} onClick={() => setAdding(true)}>
            + Add payment method
          </button>
        ))}
      <p className="mt-3 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
        Connect a payment gateway (card machine or UPI collect): available later. It needs a merchant account with the provider.
      </p>
      <Msg msg={msg} />
    </section>
  );
}

const PAYMENT_KINDS: [string, string][] = [
  ["cash", "Cash (goes in the drawer)"],
  ["upi", "UPI"],
  ["card", "Card"],
  ["wallet", "E-wallet (Paytm, GCash, GrabPay…)"],
  ["bank_transfer", "Bank transfer"],
  ["other", "Other (voucher, company account…)"],
];

function MethodOptions({
  method,
  canEdit,
  pending,
  onSave,
}: {
  method: MethodView;
  canEdit: boolean;
  pending: boolean;
  onSave: (ask: boolean, upi: string, name: string, kind: string) => void;
}) {
  const [ask, setAsk] = useState(method.ask_reference);
  const [upi, setUpi] = useState(method.upi_id ?? "");
  const [name, setName] = useState(method.name);
  const [kind, setKind] = useState(method.kind);
  const isCash = kind === "cash";
  return (
    <div className="mt-2 space-y-2 rounded-lg p-3" style={{ background: "var(--color-ground)" }}>
      <div className="grid gap-2 sm:grid-cols-2">
        <Field label="Name">
          <input className="field h-10 text-sm" value={name} maxLength={30} disabled={!canEdit} onChange={(e) => setName(e.target.value)} />
        </Field>
        <Field label="Kind">
          <select className="field h-10 text-sm" value={kind} disabled={!canEdit} onChange={(e) => setKind(e.target.value)}>
            {PAYMENT_KINDS.map(([k, label]) => (
              <option key={k} value={k}>
                {label}
              </option>
            ))}
          </select>
        </Field>
      </div>
      {isCash ? (
        <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
          Cash goes into the drawer and is counted at day close.
        </p>
      ) : (
        <Toggle
          checked={ask}
          disabled={!canEdit}
          onChange={setAsk}
          label="Ask the cashier for a reference"
          hint="e.g. the UPI transaction ID or the card's last 4 digits. Optional for the cashier; it appears in the settlement report."
        />
      )}
      {kind === "upi" && (
        <Field label="Your UPI ID" hint="Bills and the pay screen then show a scan-to-pay QR for the exact amount.">
          <input className="field h-10 text-sm" value={upi} disabled={!canEdit} onChange={(e) => setUpi(e.target.value)} placeholder="yourshop@okbank" />
        </Field>
      )}
      {canEdit && (
        <button className="btn btn-primary h-9 px-4 text-xs" disabled={pending || !name.trim()} onClick={() => onSave(ask, upi, name, kind)}>
          Save
        </button>
      )}
    </div>
  );
}

/* ------------------------------------------------------ counter tablets */

export function CountersForm({
  devices,
  canEdit,
  isThisACounter,
}: {
  devices: { id: string; name: string; lastSeen: string | null }[];
  canEdit: boolean;
  isThisACounter: boolean;
}) {
  const tz = useTz();
  const { pending, msg, run } = useRunner();
  const [name, setName] = useState(`Counter ${devices.length + 1}`);
  const [confirm, setConfirm] = useState(false);
  const setting = useRef(false);
  return (
    <section className="card p-5">
      <h2 className="text-base font-bold">Counter tablets (PIN sign-in)</h2>
      <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
        A shared tablet at the counter stays signed in. Each person unlocks it with their own PIN, and every bill records who
        took it. It locks by itself after 10 minutes without use. Set PINs on the Staff screen.
      </p>
      <ul className="mt-3 space-y-1.5 text-sm">
        {devices.length === 0 && (
          <li className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            No counter tablets yet.
          </li>
        )}
        {devices.map((d) => (
          <li key={d.id} className="flex flex-wrap items-center justify-between gap-2">
            <span>
              <b>{d.name}</b>
              <span className="ml-2 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
                {d.lastSeen ? `last unlocked ${new Date(d.lastSeen).toLocaleString("en-IN", { timeZone: tz, dateStyle: "medium", timeStyle: "short" })}` : "not used yet"}
              </span>
            </span>
            {canEdit && (
              <span className="flex flex-wrap items-center justify-end gap-3">
                <button className="text-xs font-semibold" style={{ color: "var(--color-ink-2)" }} disabled={pending} onClick={() => run(() => clearCounterLock(d.id))}>
                  Clear PIN lock
                </button>
                <ConfirmButton className="text-xs font-semibold" question={`Remove ${d.name}?`} disabled={pending} onConfirm={() => run(() => removeCounter(d.id))}>
                  Remove
                </ConfirmButton>
              </span>
            )}
          </li>
        ))}
      </ul>
      {canEdit && !isThisACounter && (
        <div className="mt-4 rounded-lg border p-3" style={{ borderColor: "var(--color-line)" }}>
          <div className="text-sm font-semibold">Make this tablet a counter</div>
          <p className="mt-1 text-[11px]" style={{ color: "var(--color-ink-3)" }}>
            Do this on the tablet itself. You will be signed out of it, and it will show the PIN screen.
          </p>
          <div className="mt-2 flex gap-2">
            <input className="field h-10 flex-1 text-sm" value={name} onChange={(e) => setName(e.target.value)} aria-label="Tablet name" />
            {confirm ? (
              <button
                className="btn btn-primary h-10 px-3 text-xs"
                disabled={pending || !name.trim()}
                onClick={() => {
                  if (setting.current) return;
                  setting.current = true;
                  run(() => setUpThisTabletAsCounter(name).finally(() => (setting.current = false)));
                }}
              >
                {pending ? "Setting up…" : "Yes, set up"}
              </button>
            ) : (
              <button className="btn h-10 border px-3 text-xs" style={{ borderColor: "var(--color-line)" }} disabled={!name.trim()} onClick={() => setConfirm(true)}>
                Set up…
              </button>
            )}
          </div>
        </div>
      )}
      <Msg msg={msg} />
    </section>
  );
}
