"use client";

import Link from "next/link";
import { useActionState, useEffect, useState } from "react";
import { authenticate, type AuthState } from "./actions";
import { SNA_CONTACT_EMAIL } from "@/lib/sna-contact";
import { PasswordInput } from "@/components/password-input";

const initial: AuthState = { error: null, notice: null };

/** The restaurant's client code is typed once per device and remembered. */
const CODE_KEY = "sna.login.clientCode.v1";

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
  /** The form is creating a sign-in from an invite code instead of signing in. */
  const [creating, setCreating] = useState(false);
  const [who, setWho] = useState("");
  const [clientCode, setClientCode] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  /** An email means an owner or invited person; anything else is a staff user code, which also needs the client code. */
  const isEmail = who.includes("@");

  useEffect(() => {
    setLinkExpired(new URLSearchParams(window.location.search).get("link") === "expired");
    try {
      const saved = window.localStorage.getItem(CODE_KEY);
      if (saved) setClientCode(saved);
    } catch {
      /* private browsing: type it each time */
    }
  }, []);

  // The form action empties the plain fields after every answer, but the two
  // password boxes are held here. Empty them too, so a wrong password is not
  // left sitting in the box; and once the account is made, go back to "sign
  // in" so the main button cannot create the account a second time.
  useEffect(() => {
    if (!state.error && !state.notice) return;
    setPassword("");
    setConfirm("");
    if (state.notice) setCreating(false);
  }, [state]);

  function rememberCode(v: string) {
    setClientCode(v);
    try {
      window.localStorage.setItem(CODE_KEY, v);
    } catch {
      /* nothing to remember */
    }
  }

  const isSignup = creating;
  const mismatch = isSignup && confirm.length > 0 && confirm !== password;

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
          <h2 className="text-3xl font-extrabold">{isSignup ? "Create your sign-in" : "Welcome back"}</h2>
          <p className="mb-6 mt-1 text-[15px]" style={{ color: "var(--color-ink-3)" }}>
            {isSignup ? "For staff who were given an invite code. You will type the code on the next page." : "Sign in to your restaurant"}
          </p>

          {/* One form for everyone. An email signs in an owner or invited person; a user code (EMP001) signs in staff and also needs the restaurant's client code. */}
          <form action={action} className="flex flex-col">
            {isSignup ? (
              <>
                <label className="mb-1.5 block text-sm font-bold" htmlFor="email">
                  Email
                </label>
                <input id="email" name="email" type="email" autoComplete="email" required className="field mb-4" placeholder="The email your invite was made for" />
              </>
            ) : (
              <>
                <label className="mb-1.5 block text-sm font-bold" htmlFor="username">
                  Email or user code
                </label>
                <input
                  id="username"
                  name="username"
                  type="text"
                  autoComplete="username"
                  autoCapitalize="none"
                  required
                  className="field mb-4"
                  placeholder="you@restaurant.com or EMP001"
                  value={who}
                  onChange={(e) => setWho(e.target.value)}
                />
                {!isEmail && (
                  <>
                    <label className="mb-1.5 block text-sm font-bold" htmlFor="clientCode">
                      Restaurant code
                    </label>
                    <p className="mb-1.5 text-xs" style={{ color: "var(--color-ink-3)" }}>
                      Ask your manager. You type it once on this device.
                    </p>
                    <input
                      id="clientCode"
                      name="clientCode"
                      type="text"
                      inputMode="numeric"
                      autoComplete="off"
                      required
                      className="field mb-4"
                      placeholder="1000"
                      pattern="[0-9]{4,6}"
                      title="Your restaurant's code, e.g. 1000"
                      value={clientCode}
                      onChange={(e) => rememberCode(e.target.value)}
                    />
                  </>
                )}
              </>
            )}

            {/* PASSWORD (shown for both) */}
            <label className="mb-1.5 block text-sm font-bold" htmlFor="password">
              Password
            </label>
            <PasswordInput
              id="password"
              name="password"
              autoComplete={isSignup ? "new-password" : "current-password"}
              required
              minLength={isSignup ? 8 : undefined}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="field"
              wrapperClassName={isSignup ? "mb-4" : "mb-2"}
              placeholder={isSignup ? "At least 8 characters" : "Your password"}
            />

            {isSignup ? (
              <>
                <label className="mb-1.5 block text-sm font-bold" htmlFor="confirm">
                  Type the password again
                </label>
                <PasswordInput
                  id="confirm"
                  name="confirm"
                  autoComplete="new-password"
                  required
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  className="field"
                  wrapperClassName="mb-2"
                  placeholder="Same password"
                  aria-invalid={mismatch}
                />
                <p className="mb-5 min-h-5 text-sm" style={{ color: "var(--color-bad)" }} role={mismatch ? "alert" : undefined}>
                  {mismatch ? "The two passwords are not the same." : ""}
                </p>
              </>
            ) : (
              <Link href="/login/forgot" className="mb-5 self-end text-sm font-bold" style={{ color: "var(--color-brand)" }}>
                Forgot password?
              </Link>
            )}

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

            <button
              type="submit"
              name="intent"
              value={isSignup ? "signup" : "signin"}
              className="btn btn-primary h-14 w-full text-base"
              disabled={pending || mismatch}
            >
              {pending ? "Please wait…" : isSignup ? "Create account" : "Sign in"}
            </button>

            {(
              <>
                <div className="my-5 flex items-center gap-3">
                  <span className="h-px flex-1" style={{ background: "var(--color-line)" }} />
                  <span className="text-xs font-semibold" style={{ color: "var(--color-ink-3)" }}>
                    {creating ? "or" : "first time here?"}
                  </span>
                  <span className="h-px flex-1" style={{ background: "var(--color-line)" }} />
                </div>

                <button
                  type="button"
                  onClick={() => {
                    setCreating((c) => !c);
                    setConfirm("");
                  }}
                  className="btn h-14 w-full text-base"
                  style={{ border: "1.5px solid var(--color-line)", background: "var(--color-surface)" }}
                  disabled={pending}
                >
                  {creating ? "I already have a sign-in" : "I have an invite code"}
                </button>
                <p className="mt-4 text-center text-sm" style={{ color: "var(--color-ink-3)" }}>
                  New restaurant? SNA sets it up for you. Write to{" "}
                  <a href={`mailto:${SNA_CONTACT_EMAIL}`} className="font-bold" style={{ color: "var(--color-brand)" }}>
                    {SNA_CONTACT_EMAIL}
                  </a>
                  .
                </p>
              </>
            )}
          </form>

          <p className="mt-8 text-center text-xs" style={{ color: "var(--color-ink-3)" }}>
            SNA POS · a product of SNA.AI
          </p>
        </div>
      </div>
    </main>
  );
}
