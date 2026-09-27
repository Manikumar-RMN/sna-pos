"use client";

import Link from "next/link";
import { useActionState, useEffect, useState } from "react";
import { authenticate, type AuthState } from "./actions";

const initial: AuthState = { error: null, notice: null };

const PLATES = [
  { name: "Dosa", bg: "#FFE6BF", ink: "#7A4400", icon: "M3 18L19 5c1.2 1.2 1.6 2.6 1 4L7 20c-1.6.4-3.2-.4-4-2zM9 14l3 3" },
  { name: "Biryani", bg: "#FFE0D6", ink: "#8C2A12", icon: "M3 11h18M5 11l1.5 8h11L19 11M9 7c0-2 6-2 6 0M12 4v3" },
  { name: "Meals", bg: "#E3F2E1", ink: "#1E4D2B", icon: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM8.5 9.5h.01M15.5 9.5h.01M12 15.5h.01" },
  { name: "Coffee", bg: "#F1E4D6", ink: "#5C3A1E", icon: "M5 8h11v6a5 5 0 0 1-5 5H10a5 5 0 0 1-5-5zM16 10h2a2 2 0 0 1 0 4h-2M8 3c0 1.5 1 1.5 1 3M12 3c0 1.5 1 1.5 1 3" },
];

function Mark({ size }: { size: number }) {
  return (
    <span className="grid shrink-0 place-items-center rounded-full" style={{ width: size, height: size, background: "var(--color-accent)" }}>
      <svg width={size * 0.58} height={size * 0.58} viewBox="0 0 24 24" fill="none" stroke="#1B1208" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M3 12h18a9 6 0 0 1-18 0z" />
        <path d="M8 8c0-2 1.5-3 1.5-4.5M12 8c0-2 1.5-3 1.5-4.5M16 8c0-2 1.5-3 1.5-4.5" />
      </svg>
    </span>
  );
}

export default function LoginPage() {
  const [state, action, pending] = useActionState(authenticate, initial);
  const [linkExpired, setLinkExpired] = useState(false);
  useEffect(() => {
    setLinkExpired(new URLSearchParams(window.location.search).get("link") === "expired");
  }, []);

  return (
    <main className="flex min-h-screen gap-3 p-3">
      {/* Food panel: tablet and desktop only */}
      <section
        className="kolam hidden w-[46%] max-w-[640px] flex-col justify-between rounded-[28px] p-10 text-white lg:flex"
        style={{ background: "var(--color-brand)" }}
      >
        <div className="flex items-center gap-3">
          <Mark size={52} />
          <span className="font-display text-2xl font-extrabold">SNA POS</span>
        </div>
        <div className="flex flex-col gap-4">
          <h1 className="text-5xl font-extrabold leading-[1.05]">
            From kitchen
            <br />
            to counter,
            <br />
            <span style={{ color: "var(--color-accent)" }}>served fast.</span>
          </h1>
          <p className="max-w-md text-[17px] leading-relaxed" style={{ color: "rgba(255,255,255,0.82)" }}>
            Billing, kitchen tickets, tables and daily reports for restaurants and cafés, with GST, VAT and SST ready.
          </p>
        </div>
        <div className="grid grid-cols-4 gap-2.5">
          {PLATES.map((p) => (
            <div key={p.name} className="flex h-24 flex-col items-center justify-center gap-1.5 rounded-[20px]" style={{ background: p.bg, color: p.ink }}>
              <svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d={p.icon} />
              </svg>
              <span className="text-[13px] font-extrabold">{p.name}</span>
            </div>
          ))}
        </div>
      </section>

      <div className="flex flex-1 items-center justify-center px-2 py-8">
        <div className="w-full max-w-[420px]">
          <div className="mb-7 flex items-center gap-3 lg:hidden">
            <Mark size={44} />
            <span className="font-display text-xl font-extrabold">SNA POS</span>
          </div>
          <h2 className="text-3xl font-extrabold">Welcome back</h2>
          <p className="mb-6 mt-1 text-[15px]" style={{ color: "var(--color-ink-3)" }}>
            Sign in to your restaurant
          </p>

          {/* One form. Both buttons submit the same email + password; the button's
              own name/value ("intent") tells the server which to do. */}
          <form action={action} className="flex flex-col">
            <label className="mb-1.5 block text-sm font-bold" htmlFor="email">
              Email
            </label>
            <input id="email" name="email" type="email" autoComplete="email" required className="field mb-4" placeholder="owner@restaurant.com" />

            <label className="mb-1.5 block text-sm font-bold" htmlFor="password">
              Password
            </label>
            <input
              id="password"
              name="password"
              type="password"
              autoComplete="current-password"
              required
              className="field mb-2"
              placeholder="Your password"
            />
            <Link href="/login/forgot" className="mb-5 self-end text-sm font-bold" style={{ color: "var(--color-brand)" }}>
              Forgot password?
            </Link>

            {state.error && (
              <p className="mb-4 rounded-xl px-3 py-2 text-sm" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }} role="alert">
                {state.error}
              </p>
            )}
            {linkExpired && !state.error && (
              <p className="mb-4 rounded-xl px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-warn-soft)", color: "var(--color-ink-2)" }}>
                That link did not work. It may have expired or been used already, or it was opened on a different device from the one where you asked for it.
                Ask for a new one with &ldquo;Forgot password?&rdquo; and open it on the same device.
              </p>
            )}
            {state.notice && (
              <p className="mb-4 rounded-xl px-3 py-2 text-sm" style={{ background: "var(--color-ok-soft)", color: "var(--color-ok)" }} role="status">
                {state.notice}
              </p>
            )}

            <button type="submit" name="intent" value="signin" className="btn btn-primary h-14 w-full text-base" disabled={pending}>
              {pending ? "Please wait…" : "Sign in"}
            </button>

            <div className="my-5 flex items-center gap-3">
              <span className="h-px flex-1" style={{ background: "var(--color-line)" }} />
              <span className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                new restaurant?
              </span>
              <span className="h-px flex-1" style={{ background: "var(--color-line)" }} />
            </div>

            <button
              type="submit"
              name="intent"
              value="signup"
              className="btn h-14 w-full text-base"
              style={{ border: "1.5px solid var(--color-line)", background: "var(--color-surface)" }}
              disabled={pending}
            >
              Create an account
            </button>
          </form>

          <p className="mt-8 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>
            SNA POS · a product of SNA.AI
          </p>
        </div>
      </div>
    </main>
  );
}
