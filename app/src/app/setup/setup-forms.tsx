"use client";

import { useActionState, useState } from "react";
import { createRestaurant, joinWithCode, type SetupState } from "./actions";

const initial: SetupState = { error: null };

function ErrorBox({ text }: { text: string | null }) {
  if (!text) return null;
  return (
    <p className="mb-4 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
      {text}
    </p>
  );
}

export type CountryOption = { code: string; name: string; taxName: string; taxIdLabel: string; note: string };

export function SetupForms({ email, countries }: { email: string; countries: CountryOption[] }) {
  const [mode, setMode] = useState<"choose" | "join" | "create">("choose");
  const [countryCode, setCountryCode] = useState(countries.find((c) => c.code === "IN")?.code ?? countries[0]?.code ?? "IN");
  const country = countries.find((c) => c.code === countryCode);
  const [createState, createAction, creating] = useActionState(createRestaurant, initial);
  const [joinState, joinAction, joining] = useActionState(joinWithCode, initial);

  if (mode === "choose") {
    return (
      <div className="space-y-3">
        <p className="text-sm" style={{ color: "var(--color-ink-2)" }}>
          Signed in as <b>{email}</b>. What would you like to do?
        </p>
        <button onClick={() => setMode("join")} className="card block w-full p-5 text-left">
          <div className="font-bold">I work at a restaurant that uses SNA POS</div>
          <div className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Enter the invite code your owner or manager gave you.
          </div>
        </button>
        <button onClick={() => setMode("create")} className="card block w-full p-5 text-left">
          <div className="font-bold">I own a restaurant and want to set it up</div>
          <div className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Creates your restaurant, staff roles, tax setup and receipt settings.
          </div>
        </button>
      </div>
    );
  }

  if (mode === "join") {
    return (
      <form action={joinAction} className="card p-5">
        <h2 className="text-base font-bold">Join with an invite code</h2>
        <p className="mb-4 mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          The code only works for the email it was made for: <b>{email}</b>.
        </p>
        <input
          name="code"
          className="field mb-4 text-center text-2xl font-bold uppercase tracking-[0.3em]"
          placeholder="ABCD-2345"
          maxLength={9}
          autoComplete="off"
          autoFocus
        />
        <ErrorBox text={joinState.error} />
        <button type="submit" className="btn btn-primary w-full" disabled={joining}>
          {joining ? "Checking…" : "Join restaurant"}
        </button>
        <button type="button" onClick={() => setMode("choose")} className="mt-3 w-full text-sm font-semibold" style={{ color: "var(--color-ink-3)" }}>
          ← Back
        </button>
      </form>
    );
  }

  return (
    <form action={createAction} className="card p-5">
      <label className="mb-1.5 block text-sm font-semibold" htmlFor="legal_name">
        Registered business name
      </label>
      <input id="legal_name" name="legal_name" required className="field mb-4" placeholder="Anna Mess Pvt Ltd" />

      <label className="mb-1.5 block text-sm font-semibold" htmlFor="trading_name">
        Name customers see
      </label>
      <input id="trading_name" name="trading_name" required className="field mb-1" placeholder="Anna Mess" />
      <p className="mb-4 text-xs" style={{ color: "var(--color-ink-3)" }}>
        This prints at the top of every bill.
      </p>

      <label className="mb-1.5 block text-sm font-semibold" htmlFor="owner_name">
        Your name
      </label>
      <input id="owner_name" name="owner_name" required className="field mb-4" placeholder="e.g. Priya Raman" />

      <label className="mb-1.5 block text-sm font-semibold" htmlFor="country_code">
        Country
      </label>
      <select id="country_code" name="country_code" className="field mb-1" value={countryCode} onChange={(e) => setCountryCode(e.target.value)}>
        {countries.map((c) => (
          <option key={c.code} value={c.code}>
            {c.name}
          </option>
        ))}
      </select>
      <p className="mb-4 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Sets your currency, {country?.taxName ?? "tax"} rates, receipt layout and payment methods. You can change rates later in Settings.
        {country?.note ? ` ${country.note}` : ""}
      </p>

      <div className="mb-4 grid grid-cols-3 gap-3">
        <div className="col-span-2">
          <label className="mb-1.5 block text-sm font-semibold" htmlFor="branch_name">
            Branch name
          </label>
          <input id="branch_name" name="branch_name" className="field" defaultValue="Main Branch" />
        </div>
        <div>
          <label className="mb-1.5 block text-sm font-semibold" htmlFor="branch_code">
            Code
          </label>
          <input id="branch_code" name="branch_code" className="field" defaultValue="MN" maxLength={4} />
        </div>
      </div>

      <label className="mb-1.5 block text-sm font-semibold" htmlFor="tax_registration_no">
        {country?.taxIdLabel ?? "Tax number"} <span className="font-normal" style={{ color: "var(--color-ink-3)" }}>(optional)</span>
      </label>
      <input
        id="tax_registration_no"
        name="tax_registration_no"
        className="field mb-5 uppercase"
        placeholder={countryCode === "IN" ? "33AAACA0000A1Z5" : ""}
        maxLength={countryCode === "IN" ? 15 : 30}
      />

      <ErrorBox text={createState.error} />

      <button type="submit" className="btn btn-primary w-full" disabled={creating}>
        {creating ? "Setting up…" : "Create my restaurant"}
      </button>
      <button type="button" onClick={() => setMode("choose")} className="mt-3 w-full text-sm font-semibold" style={{ color: "var(--color-ink-3)" }}>
        ← Back
      </button>
      <p className="mt-4 text-xs" style={{ color: "var(--color-ink-3)" }}>
        Tax rates are set to {country?.name ?? "your country"}&rsquo;s standard restaurant {country?.taxName ?? "tax"} as a starting point. Confirm them with your accountant before issuing real bills.
      </p>
    </form>
  );
}
