"use client";

import Link from "next/link";
import { useActionState } from "react";
import { changePassword, type PasswordState } from "./actions";

const initial: PasswordState = { error: null };

export function PasswordForm({ allowCancel }: { allowCancel: boolean }) {
  const [state, action, pending] = useActionState(changePassword, initial);
  return (
    <form action={action} className="card p-5">
      <label className="mb-1.5 block text-sm font-semibold" htmlFor="password">
        New password
      </label>
      <input id="password" name="password" type="password" autoComplete="new-password" required minLength={8} className="field mb-4" />
      <label className="mb-1.5 block text-sm font-semibold" htmlFor="confirm">
        Type it again
      </label>
      <input id="confirm" name="confirm" type="password" autoComplete="new-password" required minLength={8} className="field mb-5" />
      {state.error && (
        <p className="mb-4 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {state.error}
        </p>
      )}
      <button type="submit" className="btn btn-primary w-full" disabled={pending}>
        {pending ? "Saving…" : "Save password"}
      </button>
      {allowCancel && (
        <Link href="/dashboard" className="mt-3 block text-center text-sm font-semibold" style={{ color: "var(--color-ink-3)" }}>
          Cancel
        </Link>
      )}
    </form>
  );
}
