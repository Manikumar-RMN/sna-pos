"use client";

import { useActionState } from "react";
import { signInToConsole, type ConsoleSignInState } from "./actions";

const initial: ConsoleSignInState = { error: null };

export function ConsoleSignIn() {
  const [state, action, pending] = useActionState(signInToConsole, initial);
  return (
    <form action={action} className="space-y-4">
      <div>
        <label htmlFor="sna-email" className="mb-1 block text-sm font-semibold">
          Email
        </label>
        <input id="sna-email" name="email" type="email" className="field" autoComplete="username" required />
      </div>
      <div>
        <label htmlFor="sna-password" className="mb-1 block text-sm font-semibold">
          Password
        </label>
        <input id="sna-password" name="password" type="password" className="field" autoComplete="current-password" required />
      </div>
      {state.error && (
        <p role="alert" className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {state.error}
        </p>
      )}
      <button type="submit" disabled={pending} className="btn btn-primary w-full">
        {pending ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}
