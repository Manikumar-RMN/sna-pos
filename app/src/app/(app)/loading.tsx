/** Shown the moment a screen is opened, while its data loads. */
export default function Loading() {
  return (
    <div className="flex flex-col gap-4" aria-busy="true" aria-label="Loading">
      <div className="h-9 w-48 animate-pulse rounded-xl" style={{ background: "var(--color-line)" }} />
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {[0, 1, 2, 3, 4, 5].map((i) => (
          <div key={i} className="h-28 animate-pulse rounded-[22px]" style={{ background: "var(--color-surface-2)", border: "1px solid var(--color-line)" }} />
        ))}
      </div>
    </div>
  );
}
