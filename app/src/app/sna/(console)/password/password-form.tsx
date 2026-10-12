"use client";

import Link from "next/link";
import { useActionState } from "react";
import { changeConsolePassword, type ConsolePasswordState } from "./actions";
import { PasswordInput } from "@/components/password-input";

const initial: ConsolePasswordState = { error: null };

export function ConsolePasswordForm() {
  const [state, action, pending] = useActionState(changeConsolePassword, initial);
  return (
    <form action={action} className="card p-5">
      <label className="mb-1.5 block text-sm font-semibold" htmlFor="sna-new-password">
        New password
      </label>
      <PasswordInput id="sna-new-password" name="password" autoComplete="new-password" required minLength={8} maxLength={72} className="field" wrapperClassName="mb-4" />
      <label className="mb-1.5 block text-sm font-semibold" htmlFor="sna-confirm-password">
        Type it again
      </label>
      <PasswordInput id="sna-confirm-password" name="confirm" autoComplete="new-password" required minLength={8} maxLength={72} className="field" wrapperClassName="mb-5" />
      {state.error && (
        <p className="mb-4 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
          {state.error}
        </p>
      )}
      <button type="submit" className="btn w-full" style={{ background: "var(--color-ink)", color: "#fff" }} disabled={pending}>
        {pending ? "Saving…" : "Save password"}
      </button>
      <Link href="/sna" className="mt-3 block text-center text-sm font-semibold" style={{ color: "var(--color-ink-3)" }}>
        Cancel
      </Link>
    </form>
  );
}
