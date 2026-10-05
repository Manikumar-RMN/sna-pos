"use client";

import Link from "next/link";
import { useActionState } from "react";
import { requestConsoleReset, type ConsoleForgotState } from "./actions";

const initial: ConsoleForgotState = { error: null };

/** Forgot password, for the SNA console. Separate from the restaurant app's page. */
export default function ConsoleForgotPage() {
  const [state, action, pending] = useActionState(requestConsoleReset, initial);
  return (
    <main className="flex min-h-screen items-center justify-center px-4 py-10" style={{ background: "var(--color-ink)" }}>
      <div className="w-full max-w-sm">
        <h1 className="font-display text-2xl font-bold text-white">Forgot your password?</h1>
        <p className="mt-1 text-sm" style={{ color: "rgba(255,255,255,0.75)" }}>
          SNA console. Enter the email you sign in with and we will send a link to choose a new password.
        </p>
        <div className="card mt-5 p-5">
          {state.sent ? (
            <div className="text-sm" style={{ color: "var(--color-ink-2)" }}>
              <p>If that email is an SNA staff sign-in, a reset link is on its way. Open it on this device. It works once.</p>
              <p className="mt-3" style={{ color: "var(--color-ink-3)" }}>
                No email after a few minutes? Check spam, then ask an SNA admin.
              </p>
            </div>
          ) : (
            <form action={action} className="space-y-4">
              <div>
                <label htmlFor="sna-forgot-email" className="mb-1 block text-sm font-semibold">
                  Email
                </label>
                <input id="sna-forgot-email" name="email" type="email" className="field" autoComplete="username" required />
              </div>
              {state.error && (
                <p role="alert" className="rounded-xl px-3 py-2 text-sm font-semibold" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
                  {state.error}
                </p>
              )}
              <button type="submit" disabled={pending} className="btn btn-primary w-full">
                {pending ? "Sending…" : "Send reset link"}
              </button>
            </form>
          )}
          <Link href="/sna/login" className="mt-4 block text-center text-sm font-bold" style={{ color: "var(--color-brand)" }}>
            Back to sign in
          </Link>
        </div>
      </div>
    </main>
  );
}
