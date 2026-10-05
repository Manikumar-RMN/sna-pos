"use client";

import Link from "next/link";
import { useState, useTransition } from "react";
import { createClientAccount, type NewClientResult } from "../actions";

type Country = { code: string; name: string; taxName: string; taxIdLabel: string; note: string };

const blank = {
  legalName: "",
  tradingName: "",
  ownerName: "",
  ownerEmail: "",
  countryCode: "IN",
  branchName: "Main Branch",
  branchCode: "MN",
  taxNo: "",
  edition: "basic",
  licenceStart: "",
  licenceExpiry: "",
};

function Field({ label, htmlFor, hint, children }: { label: string; htmlFor: string; hint?: string; children: React.ReactNode }) {
  return (
    <div>
      <label htmlFor={htmlFor} className="mb-1 block text-xs font-bold" style={{ color: "var(--color-ink-2)" }}>
        {label}
      </label>
      {children}
      {hint && (
        <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
          {hint}
        </p>
      )}
    </div>
  );
}

export function NewClientForm({ countries, canSell }: { countries: Country[]; canSell: boolean }) {
  const [f, setF] = useState({ ...blank, countryCode: countries.find((c) => c.code === "IN")?.code ?? countries[0]?.code ?? "IN" });
  const [pending, start] = useTransition();
  const [res, setRes] = useState<NewClientResult | null>(null);
  const set = (patch: Partial<typeof blank>) => setF((x) => ({ ...x, ...patch }));
  const country = countries.find((c) => c.code === f.countryCode);

  if (res?.ok) {
    return (
      <div className="card mt-4 space-y-4 p-5">
        <h2 className="font-display text-xl font-bold" style={{ color: "var(--color-ok)" }}>
          {res.tradingName} is set up
        </h2>
        <dl className="grid gap-3 text-sm sm:grid-cols-2">
          <div>
            <dt className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Client code (staff type this to sign in)
            </dt>
            <dd className="text-2xl font-bold tabular-nums tracking-wider">{res.clientCode}</dd>
          </div>
          <div>
            <dt className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
              Owner signs in with
            </dt>
            <dd className="break-all text-base font-bold">{res.ownerEmail}</dd>
          </div>
        </dl>
        {res.tempPassword ? (
          <div className="rounded-2xl p-4" style={{ background: "var(--color-warn-soft)" }}>
            <div className="text-xs font-bold" style={{ color: "var(--color-warn)" }}>
              Temporary password. It is shown only now: write it down before you leave this page.
            </div>
            <div className="mt-1 select-all break-all font-mono text-2xl font-bold tracking-wider">{res.tempPassword}</div>
            <p className="mt-2 text-sm" style={{ color: "var(--color-ink-2)" }}>
              Give it to the owner privately. They sign in at sna-pos.vercel.app, on the <b>Owner</b> tab, with their email and this password, and must then choose
              their own password.
            </p>
          </div>
        ) : (
          <p className="rounded-2xl p-4 text-sm" style={{ background: "var(--color-ok-soft)", color: "var(--color-ink-2)" }}>
            This email is an SNA staff sign-in, so its password was left as it is. Sign in on the <b>Owner</b> tab with the usual password.
          </p>
        )}
        <div className="flex flex-wrap gap-2">
          <Link href={`/sna/r/${res.id}`} className="btn px-5" style={{ background: "var(--color-ink)", color: "#fff" }}>
            Open the client page
          </Link>
          <button
            type="button"
            className="btn px-4"
            style={{ border: "1px solid var(--color-line)", color: "var(--color-ink-2)" }}
            onClick={() => {
              setRes(null);
              setF({ ...blank, countryCode: f.countryCode });
            }}
          >
            Create another client
          </button>
        </div>
      </div>
    );
  }

  return (
    <form
      className="card mt-4 space-y-5 p-5"
      onSubmit={(e) => {
        e.preventDefault();
        start(async () => setRes(await createClientAccount(f)));
      }}
    >
      <div>
        <h2 className="font-display text-lg font-bold">The restaurant</h2>
        <div className="mt-3 grid gap-4 sm:grid-cols-2">
          <Field label="Registered business name" htmlFor="nc-legal">
            <input id="nc-legal" className="field" value={f.legalName} maxLength={200} required placeholder="Anna Mess Pvt Ltd" onChange={(e) => set({ legalName: e.target.value })} />
          </Field>
          <Field label="Name customers see" htmlFor="nc-trading" hint="Prints at the top of every bill.">
            <input id="nc-trading" className="field" value={f.tradingName} maxLength={200} required placeholder="Anna Mess" onChange={(e) => set({ tradingName: e.target.value })} />
          </Field>
          <Field label="Country" htmlFor="nc-country" hint={`Sets the currency, ${country?.taxName ?? "tax"} rates and bill layout. It cannot be changed later.${country?.note ? ` ${country.note}` : ""}`}>
            <select id="nc-country" className="field" value={f.countryCode} onChange={(e) => set({ countryCode: e.target.value })}>
              {countries.map((c) => (
                <option key={c.code} value={c.code}>
                  {c.name}
                </option>
              ))}
            </select>
          </Field>
          <Field label={`${country?.taxIdLabel ?? "Tax number"} (optional)`} htmlFor="nc-tax">
            <input id="nc-tax" className="field uppercase" value={f.taxNo} maxLength={f.countryCode === "IN" ? 15 : 30} onChange={(e) => set({ taxNo: e.target.value })} />
          </Field>
          <Field label="First outlet" htmlFor="nc-branch">
            <input id="nc-branch" className="field" value={f.branchName} maxLength={120} required onChange={(e) => set({ branchName: e.target.value })} />
          </Field>
          <Field label="Outlet code" htmlFor="nc-code" hint="2 to 4 letters or digits. It starts every bill number, e.g. MN-2627-0001.">
            <input id="nc-code" className="field uppercase" value={f.branchCode} maxLength={4} required pattern="[A-Za-z0-9]{2,4}" onChange={(e) => set({ branchCode: e.target.value })} />
          </Field>
        </div>
      </div>

      <div className="border-t pt-4" style={{ borderColor: "var(--color-line)" }}>
        <h2 className="font-display text-lg font-bold">The owner</h2>
        <div className="mt-3 grid gap-4 sm:grid-cols-2">
          <Field label="Owner's name" htmlFor="nc-owner">
            <input id="nc-owner" className="field" value={f.ownerName} maxLength={120} required placeholder="Priya Raman" onChange={(e) => set({ ownerName: e.target.value })} />
          </Field>
          <Field label="Owner's email" htmlFor="nc-email" hint="They sign in with this. You get a temporary password to pass on.">
            <input id="nc-email" type="email" className="field" value={f.ownerEmail} maxLength={200} required placeholder="owner@restaurant.com" onChange={(e) => set({ ownerEmail: e.target.value })} />
          </Field>
        </div>
      </div>

      <div className="border-t pt-4" style={{ borderColor: "var(--color-line)" }}>
        <h2 className="font-display text-lg font-bold">Plan and licence</h2>
        {canSell ? (
          <div className="mt-3 grid gap-4 sm:grid-cols-3">
            <Field label="Edition" htmlFor="nc-edition">
              <select id="nc-edition" className="field" value={f.edition} onChange={(e) => set({ edition: e.target.value })}>
                <option value="basic">Basic</option>
                <option value="professional">Professional</option>
              </select>
            </Field>
            <Field label="Licence starts" htmlFor="nc-start">
              <input id="nc-start" type="date" className="field" value={f.licenceStart} onChange={(e) => set({ licenceStart: e.target.value })} />
            </Field>
            <Field label="Licence ends" htmlFor="nc-end">
              <input id="nc-end" type="date" className="field" value={f.licenceExpiry} min={f.licenceStart || undefined} onChange={(e) => set({ licenceExpiry: e.target.value })} />
            </Field>
          </div>
        ) : (
          <p className="mt-2 text-sm" style={{ color: "var(--color-ink-3)" }}>
            The client starts on Basic with no licence date. Sales or Admin set the edition and the licence dates on the client page.
          </p>
        )}
        <p className="mt-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
          With no end date the restaurant is not limited. With an end date it sees a reminder from 15 days before, and becomes read-only the morning after.
          Add-ons and the invoice go on the client&rsquo;s Sales history tab afterwards.
        </p>
      </div>

      {res && !res.ok && (
        <p role="alert" className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {res.error}
        </p>
      )}
      <button type="submit" className="btn px-6" style={{ background: "var(--color-ink)", color: "#fff" }} disabled={pending}>
        {pending ? "Creating…" : "Create the client"}
      </button>
    </form>
  );
}
