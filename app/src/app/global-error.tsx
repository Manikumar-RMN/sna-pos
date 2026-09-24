"use client";

/**
 * Last-resort handler: catches an error in the root layout itself, where the
 * normal error boundary and app styles are not available. It must render its
 * own <html>/<body>. Kept deliberately plain and self-contained.
 */
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  console.error("SNA POS fatal error:", error?.message, error?.digest);

  return (
    <html lang="en">
      <body
        style={{
          margin: 0,
          minHeight: "100vh",
          display: "grid",
          placeItems: "center",
          fontFamily: "system-ui, -apple-system, Segoe UI, sans-serif",
          background: "#F6F5FB",
          color: "#16132A",
          padding: 16,
        }}
      >
        <div style={{ maxWidth: 380, textAlign: "center" }}>
          <div
            style={{
              width: 44,
              height: 44,
              borderRadius: 10,
              background: "#6D4AFF",
              color: "#fff",
              fontWeight: 700,
              fontSize: 13,
              display: "grid",
              placeItems: "center",
              margin: "0 auto 14px",
            }}
          >
            SNA
          </div>
          <h1 style={{ fontSize: 18, margin: "0 0 8px" }}>SNA POS is temporarily unavailable</h1>
          <p style={{ fontSize: 14, color: "#7C7694", margin: "0 0 18px" }}>
            Something went wrong loading the app. Please try again in a moment.
          </p>
          <button
            onClick={reset}
            style={{
              minHeight: 44,
              padding: "0 20px",
              borderRadius: 10,
              border: 0,
              background: "#6D4AFF",
              color: "#fff",
              fontWeight: 600,
              fontSize: 15,
              cursor: "pointer",
            }}
          >
            Try again
          </button>
        </div>
      </body>
    </html>
  );
}
