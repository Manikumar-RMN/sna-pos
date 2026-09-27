"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { signOutCounter, unlockWithPin } from "./actions";

const KEYS = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "clear", "0", "back"];

export function PinPad({ removed = false }: { removed?: boolean }) {
  const router = useRouter();
  const [pin, setPin] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const busy = useRef(false);

  function submit(value: string) {
    if (busy.current || value.length < 4) return;
    busy.current = true;
    setError(null);
    start(async () => {
      try {
        const r = await unlockWithPin(value);
        if (!r.ok) {
          setError(r.error);
          setPin("");
          return;
        }
        router.replace(r.next);
      } catch {
        setError("Could not reach the server. Check the internet connection.");
        setPin("");
      } finally {
        busy.current = false;
      }
    });
  }

  function press(k: string) {
    if (busy.current) return;
    setError(null);
    if (k === "clear") return setPin("");
    if (k === "back") return setPin((p) => p.slice(0, -1));
    setPin((p) => (p.length >= 6 ? p : p + k));
  }

  // Physical keyboards work too (a tablet with a keyboard, or a desktop).
  useEffect(() => {
    if (removed) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.repeat) return;
      if (/^\d$/.test(e.key)) {
        e.preventDefault();
        press(e.key);
      } else if (e.key === "Backspace") {
        e.preventDefault();
        press("back");
      } else if (e.key === "Enter") {
        e.preventDefault();
        submit(pin);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  return (
    <div className="mt-6">
      {!removed && (
        <>
          <div className="mb-4 flex justify-center gap-3" aria-label={`${pin.length} digits entered`}>
            {Array.from({ length: Math.max(4, pin.length) }).map((_, i) => (
              <span
                key={i}
                className="h-3.5 w-3.5 rounded-full border-2"
                style={{ borderColor: "var(--color-brand)", background: i < pin.length ? "var(--color-brand)" : "transparent" }}
              />
            ))}
          </div>
          {error && (
            <p className="mb-3 rounded-lg px-3 py-2 text-sm" role="alert" style={{ background: "var(--color-bad-soft)", color: "var(--color-bad)" }}>
              {error}
            </p>
          )}
          <div className="grid grid-cols-3 gap-2">
            {KEYS.map((k) => (
              <button
                key={k}
                type="button"
                onClick={() => press(k)}
                onMouseDown={(e) => e.preventDefault()}
                disabled={pending}
                className="h-16 rounded-xl border text-xl font-semibold active:scale-[0.97]"
                style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}
                aria-label={k === "back" ? "Delete last digit" : k === "clear" ? "Clear" : k}
              >
                {k === "back" ? "⌫" : k === "clear" ? "C" : k}
              </button>
            ))}
          </div>
          <button
            type="button"
            className="btn btn-primary mt-3 w-full"
            disabled={pending || pin.length < 4}
            onMouseDown={(e) => e.preventDefault()}
            onClick={() => submit(pin)}
          >
            {pending ? "Checking…" : "Unlock"}
          </button>
        </>
      )}

      <div className="mt-8 text-xs" style={{ color: "var(--color-ink-3)" }}>
        {removed ? (
          <form action={signOutCounter}>
            <button type="submit" className="btn btn-primary w-full">
              Sign this tablet out
            </button>
          </form>
        ) : (
          <p>To stop using this tablet as a counter, a manager unlocks it and removes it in Settings → Counter tablets.</p>
        )}
      </div>
    </div>
  );
}
