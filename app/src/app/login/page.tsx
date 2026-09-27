"use client";

import Link from "next/link";
import { useActionState, useEffect, useState } from "react";
import { authenticate, type AuthState } from "./actions";

const initial: AuthState = { error: null, notice: null };

export default function LoginPage() {
  const [state, action, pending] = useActionState(authenticate, initial);
  const [linkExpired, setLinkExpired] = useState(false);
  useEffect(() => {
    setLinkExpired(new URLSearchParams(window.location.search).get("link") === "expired");
  }, []);

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

        {/* One form. Both buttons submit the same email + password; the button's
            own name/value ("intent") tells the server which to do. */}
        <form action={action} className="card p-5">
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

          {state.error && (
            <p
              className="mb-4 rounded-lg px-3 py-2 text-sm"
              style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}
              role="alert"
            >
              {state.error}
            </p>
          )}
          {linkExpired && !state.error && (
            <p className="mb-4 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-warn-soft)", color: "var(--color-ink-2)" }}>
              That link did not work. It may have expired or been used already, or it was opened on a different device from the one where you asked for it. Ask for a new one with &ldquo;Forgot password?&rdquo; and open it on the same device.
            </p>
          )}
          {state.notice && (
            <p
              className="mb-4 rounded-lg px-3 py-2 text-sm"
              style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }}
              role="status"
            >
              {state.notice}
            </p>
          )}

          <button
            type="submit"
            name="intent"
            value="signin"
            className="btn btn-primary w-full"
            disabled={pending}
          >
            {pending ? "Please wait…" : "Sign in"}
          </button>
          <Link href="/login/forgot" className="mt-3 block text-center text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
            Forgot password?
          </Link>

          <div className="my-4 flex items-center gap-3">
            <span className="h-px flex-1" style={{ background: "var(--color-line)" }} />
            <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>
              new restaurant?
            </span>
            <span className="h-px flex-1" style={{ background: "var(--color-line)" }} />
          </div>

          <button
            type="submit"
            name="intent"
            value="signup"
            className="btn w-full"
            style={{ border: "1px solid var(--color-line)", background: "var(--color-surface)" }}
            disabled={pending}
          >
            Create an account
          </button>
        </form>

        <p className="mt-8 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>
          SNA POS · a product of SNA.AI · in development
        </p>
      </div>
    </main>
  );
}
