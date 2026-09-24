"use client";

/**
 * Catches unexpected errors inside the app and shows a calm message instead of
 * a raw browser 500. The actual error is logged to the server (visible in
 * Vercel's logs) but never shown to the user — error details can leak
 * internals, so the screen stays generic.
 */
export default function AppError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  // Reaches Vercel's runtime logs; safe place to add Sentry later.
  console.error("SNA POS app error:", error?.message, error?.digest);

  return (
    <div className="mx-auto max-w-md px-4 py-16 text-center">
      <div
        className="mx-auto mb-4 grid h-12 w-12 place-items-center rounded-xl text-lg"
        style={{ background: "var(--color-warn-soft)", color: "var(--color-warn)" }}
      >
        !
      </div>
      <h1 className="text-lg font-bold">Something went wrong</h1>
      <p className="mt-2 text-sm" style={{ color: "var(--color-ink-3)" }}>
        The screen ran into a problem. Nothing was lost — please try again.
      </p>
      {error?.digest && (
        <p className="mt-1 text-xs" style={{ color: "var(--color-ink-3)" }}>
          Reference: {error.digest}
        </p>
      )}
      <button onClick={reset} className="btn btn-primary mt-5" style={{ minWidth: 160 }}>
        Try again
      </button>
    </div>
  );
}
