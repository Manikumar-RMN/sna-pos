"use client";

import Link from "next/link";
import { useActionState } from "react";
import { requestReset, type ForgotState } from "./actions";

const initial: ForgotState = { error: null };

export default function ForgotPage() {
  const [state, action, pending] = useActionState(requestReset, initial);
  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10">
      <div className="w-full max-w-sm">
        <h1 className="text-xl font-bold tracking-tight">Forgot your password?</h1>
        <p className="mt-1 mb-5 text-sm" style={{ color: "var(--color-ink-3)" }}>
          Enter the email you sign in with. We&rsquo;ll send a link to choose a new password.
        </p>
        {state.sent ? (
          <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
            <p>
              If that email has an SNA POS account, a reset link is on its way. Open it on this device. It works once.
            </p>
            <p className="mt-3" style={{ color: "var(--color-ink-3)" }}>
              No email after a few minutes? Check spam, or ask your owner or manager to reset your password from the Staff
              screen.
            </p>
          </div>
        ) : (
          <form action={action} className="card p-5">
            <label className="mb-1.5 block text-sm font-semibold" htmlFor="email">
              Email
            </label>
            <input id="email" name="email" type="email" autoComplete="email" required className="field mb-4" placeholder="you@restaurant.com" />
            {state.error && (
              <p className="mb-4 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
                {state.error}
              </p>
            )}
            <button type="submit" className="btn btn-primary w-full" disabled={pending}>
              {pending ? "Sending…" : "Send reset link"}
            </button>
          </form>
        )}
        <Link href="/login" className="mt-4 block text-center text-sm font-semibold" style={{ color: "var(--color-brand)" }}>
          ← Back to sign in
        </Link>
      </div>
    </main>
  );
}
