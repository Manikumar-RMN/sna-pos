"use client";

import { useActionState } from "react";
import { joinWithCode, type SetupState } from "./actions";

const initial: SetupState = { error: null };

/**
 * A sign-in that is not part of any restaurant yet can do one thing: join the
 * restaurant that invited it. New restaurants are set up by SNA, not here.
 */
export function SetupForms({ email, contact }: { email: string; contact: string }) {
  const [joinState, joinAction, joining] = useActionState(joinWithCode, initial);
  return (
    <div className="space-y-4">
      <form action={joinAction} className="card p-5">
        <h2 className="text-base font-bold">Join with an invite code</h2>
        <p className="mb-4 mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          Signed in as <b>{email}</b>. Enter the code your owner or manager gave you. It only works for the email it was made for.
        </p>
        <label htmlFor="invite-code" className="sr-only">
          Invite code
        </label>
        <input
          id="invite-code"
          name="code"
          className="field mb-4 text-center text-2xl font-bold uppercase tracking-[0.3em]"
          placeholder="ABCD-2345"
          maxLength={9}
          autoComplete="off"
          autoFocus
        />
        {joinState.error && (
          <p className="mb-4 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
            {joinState.error}
          </p>
        )}
        <button type="submit" className="btn btn-primary w-full" disabled={joining}>
          {joining ? "Checking…" : "Join restaurant"}
        </button>
      </form>
      <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
        <b>Want SNA POS for your own restaurant?</b> SNA sets up every new restaurant. Write to{" "}
        <a href={`mailto:${contact}`} className="font-bold" style={{ color: "var(--color-brand)" }}>
          {contact}
        </a>{" "}
        and you will get your sign-in from SNA.
      </div>
    </div>
  );
}
