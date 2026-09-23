"use client";

import { useActionState } from "react";
import { signIn, signUp, type AuthState } from "./actions";

const initial: AuthState = { error: null };

export default function LoginPage() {
  const [signInState, signInAction, signingIn] = useActionState(signIn, initial);
  const [signUpState, signUpAction, signingUp] = useActionState(signUp, initial);
  const error = signInState.error ?? signUpState.error;

  return (
    <main className="min-h-screen flex items-center justify-center px-4 py-10">
      <div className="w-full max-w-sm">
        <div className="mb-7 text-center">
          <div
            className="mx-auto mb-3 grid h-12 w-12 place-items-center rounded-xl text-sm font-bold text-white"
            style={{ background: "var(--color-brand)" }}
          >
            SNA
          </div>
          <h1 className="text-xl font-bold tracking-tight">SNA POS</h1>
          <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
            Sign in to your restaurant
          </p>
        </div>

        <form action={signInAction} className="card p-5">
          <label className="mb-1.5 block text-sm font-semibold" htmlFor="email">
            Email
          </label>
          <input
            id="email"
            name="email"
            type="email"
            autoComplete="email"
            required
            className="field mb-4"
            placeholder="you@restaurant.com"
          />

          <label className="mb-1.5 block text-sm font-semibold" htmlFor="password">
            Password
          </label>
          <input
            id="password"
            name="password"
            type="password"
            autoComplete="current-password"
            required
            className="field mb-5"
            placeholder="••••••••"
          />

          {error && (
            <p
              className="mb-4 rounded-lg px-3 py-2 text-sm"
              style={{
                background: "var(--color-bad-soft)",
                color: "var(--color-bad)",
              }}
              role="alert"
            >
              {error}
            </p>
          )}

          <button
            type="submit"
            className="btn btn-primary w-full"
            disabled={signingIn || signingUp}
          >
            {signingIn ? "Signing in…" : "Sign in"}
          </button>
        </form>

        <form action={signUpAction} className="mt-4 text-center">
          <p className="text-sm" style={{ color: "var(--color-ink-3)" }}>
            New restaurant?{" "}
            <button
              type="submit"
              className="font-semibold underline"
              style={{ color: "var(--color-brand)" }}
              disabled={signingIn || signingUp}
            >
              {signingUp ? "Creating…" : "Create an account"}
            </button>
          </p>
          <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
            Fill in the email and password above first.
          </p>
        </form>

        <p className="mt-8 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>
          SNA POS · a product of SNA.AI · in development
        </p>
      </div>
    </main>
  );
}
