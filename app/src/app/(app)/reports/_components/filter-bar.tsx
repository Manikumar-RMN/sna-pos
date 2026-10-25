import Link from "next/link";

const PRESETS = [
  { key: "today", label: "Today" },
  { key: "yesterday", label: "Yesterday" },
  { key: "7d", label: "Last 7 days" },
  { key: "month", label: "This month" },
  { key: "lastmonth", label: "Last month" },
];

/** Date presets and a custom range for one report page (`basePath` is the page's own URL). */
export function FilterBar({ basePath, from, to, range, today }: { basePath: string; from: string; to: string; range: string; today: string }) {
  return (
    <div className="mb-5 flex flex-wrap items-center gap-2">
      {PRESETS.map((p) => (
        <Link
          key={p.key}
          href={`${basePath}?range=${p.key}`}
          className="rounded-full border px-3 py-1.5 text-xs font-semibold"
          style={{
            borderColor: range === p.key ? "var(--color-brand)" : "var(--color-line)",
            background: range === p.key ? "var(--color-brand-soft)" : "var(--color-surface)",
            color: range === p.key ? "var(--color-brand-strong)" : "var(--color-ink-2)",
          }}
        >
          {p.label}
        </Link>
      ))}
      <form action={basePath} className="flex flex-wrap items-center gap-1.5">
        <input type="date" name="from" defaultValue={from} max={today} className="field h-9 w-36 text-xs" />
        <span className="text-xs" style={{ color: "var(--color-ink-3)" }}>to</span>
        <input type="date" name="to" defaultValue={to} max={today} className="field h-9 w-36 text-xs" />
        <button className="rounded-lg border px-3 py-2 text-xs font-semibold" style={{ borderColor: "var(--color-line)", background: "var(--color-surface)" }}>
          Show
        </button>
      </form>
    </div>
  );
}
