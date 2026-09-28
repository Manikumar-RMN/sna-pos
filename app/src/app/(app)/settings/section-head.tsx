/** Title and one-line explanation at the top of a settings section. */
export function SectionHead({ title, children }: { title: string; children?: React.ReactNode }) {
  return (
    <div className="mb-4">
      <h2 className="text-xl font-bold">{title}</h2>
      {children && (
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          {children}
        </p>
      )}
    </div>
  );
}

/** Shown when someone opens a section their role cannot use. */
export function NoAccess() {
  return (
    <div className="card p-5 text-sm" style={{ color: "var(--color-ink-2)" }}>
      Your role cannot open this section. Ask the owner if you need it.
    </div>
  );
}
