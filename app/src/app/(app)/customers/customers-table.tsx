"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { money } from "@/lib/format";
import {
  CUSTOMER_FILTERS,
  CUSTOMER_SORTS,
  PAGE_SIZE,
  customersHref,
  formatPhone,
  isLapsed,
  lastVisitText,
  searchHint,
  type CustomerFilter,
  type CustomerRow,
  type CustomerSort,
} from "@/lib/customers";
import { exportCustomers } from "./actions";

type Col = { key: CustomerSort | null; label: string; right?: boolean };

export function CustomersTable({
  rows,
  total,
  q,
  filter,
  sort,
  page,
  today,
  currency,
  canExport,
  showPoints,
  error,
}: {
  rows: CustomerRow[];
  total: number;
  q: string;
  filter: CustomerFilter;
  sort: CustomerSort;
  page: number;
  today: string;
  currency: string;
  canExport: boolean;
  showPoints: boolean;
  error: string | null;
}) {
  const router = useRouter();
  const m = (n: number) => money(n, currency);
  const [text, setText] = useState(q);
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const first = useRef(true);

  // Search as the person types, after a short pause. The list is read again on the server.
  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    if (text.trim() === q.trim()) return;
    const t = setTimeout(() => router.replace(customersHref({ q: text, filter, sort })), 400);
    return () => clearTimeout(t);
  }, [text, q, filter, sort, router]);

  const sorts = CUSTOMER_SORTS.filter((s) => showPoints || s.key !== "points");
  const cols: Col[] = [
    { key: "name", label: "Name" },
    { key: null, label: "Phone" },
    { key: "visits", label: "Visits", right: true },
    { key: "spend", label: "Spend", right: true },
    { key: "last_visit", label: "Last visit" },
    ...(showPoints ? [{ key: "points" as const, label: "Points", right: true }] : []),
  ];
  const pages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const hint = searchHint(text);

  function download() {
    setNote(null);
    start(async () => {
      const r = await exportCustomers(q, filter, sort);
      if (!r.ok) return setNote({ ok: false, text: r.error });
      const url = URL.createObjectURL(new Blob([r.csv], { type: "text/csv;charset=utf-8" }));
      const a = document.createElement("a");
      a.href = url;
      a.download = r.filename;
      a.click();
      URL.revokeObjectURL(url);
      setNote({ ok: true, text: `${r.rows} guests exported${r.truncated ? " (the first rows only; narrow the filter for the rest)" : ""}. The export is recorded in the audit log.` });
    });
  }

  return (
    <div className="mx-auto max-w-5xl space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold tracking-tight">Customers</h1>
          <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>
            Guests are added when their phone number is put on a bill. Visits and spend count paid bills only; voided bills and refunds are left out.
          </p>
        </div>
        {canExport && (
          <button className="btn border" style={{ borderColor: "var(--color-line)", minHeight: 40, padding: "0 14px" }} disabled={pending || total === 0} onClick={download}>
            {pending ? "Preparing…" : "Export CSV"}
          </button>
        )}
      </div>

      <section className="card space-y-3 p-4">
        <div className="flex flex-wrap items-center gap-2">
          <input
            className="field max-w-xs"
            type="search"
            placeholder="Search name or phone"
            aria-label="Search guests by name or phone"
            value={text}
            onChange={(e) => setText(e.target.value)}
          />
          <div className="flex flex-wrap gap-1.5" role="group" aria-label="Filter guests">
            {CUSTOMER_FILTERS.map((f) => (
              <Link
                key={f.key}
                href={customersHref({ q, filter: f.key, sort })}
                title={f.help}
                aria-current={f.key === filter ? "true" : undefined}
                className="rounded-full border px-3 py-1.5 text-xs font-semibold"
                style={f.key === filter ? { background: "var(--color-brand)", color: "#fff", borderColor: "var(--color-brand)" } : { borderColor: "var(--color-line)", color: "var(--color-ink-2)" }}
              >
                {f.label}
              </Link>
            ))}
          </div>
        </div>
        <label className="flex items-center gap-2 text-xs md:hidden" style={{ color: "var(--color-ink-3)" }}>
          Sort by
          <select className="field w-40" value={sort} aria-label="Sort guests by" onChange={(e) => router.push(customersHref({ q, filter, sort: e.target.value as CustomerSort }))}>
            {sorts.map((s) => <option key={s.key} value={s.key}>{s.label}</option>)}
          </select>
        </label>
        {hint && <p className="text-xs" style={{ color: "var(--color-ink-3)" }}>{hint}</p>}
        {note && <p role="status" className="text-sm font-semibold" style={{ color: note.ok ? "var(--color-ok)" : "var(--color-bad)" }}>{note.text}</p>}
        {error && <p role="alert" className="text-sm font-semibold" style={{ color: "var(--color-bad)" }}>{error}</p>}

        {rows.length === 0 && !error ? (
          <p className="py-4 text-sm" style={{ color: "var(--color-ink-3)" }}>
            {q || filter !== "all" ? "No guests match. Try a shorter search or the All filter." : "No guests yet. Put a phone number on a bill and the guest appears here."}
          </p>
        ) : (
          <>
            {/* Phone and tablet: one card per guest. */}
            <ul className="space-y-2 md:hidden">
              {rows.map((r) => (
                <li key={r.id}>
                  <Link href={`/customers/${r.id}`} className="block rounded-xl border p-3" style={{ borderColor: "var(--color-line)" }}>
                    <div className="flex items-baseline justify-between gap-2">
                      <b className="truncate">{r.name}</b>
                      {showPoints && <span className="text-sm tabular-nums">{r.points} pts</span>}
                    </div>
                    <div className="text-xs" style={{ color: "var(--color-ink-3)" }}>{formatPhone(r.phone)}</div>
                    <div className="mt-1 flex flex-wrap justify-between gap-x-3 text-xs" style={{ color: "var(--color-ink-2)" }}>
                      <span>{r.visits} {r.visits === 1 ? "visit" : "visits"}</span>
                      <span>{m(r.spend)}</span>
                      <span style={isLapsed(r.lastVisitOn, today) ? { color: "var(--color-warn)" } : undefined}>{lastVisitText(r.lastVisitOn, today)}</span>
                    </div>
                  </Link>
                </li>
              ))}
            </ul>

            {/* Desktop table. Column titles that can sort are links. */}
            <div className="hidden overflow-x-auto md:block">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-xs" style={{ color: "var(--color-ink-3)" }}>
                    {cols.map((c) => (
                      <th key={c.label} className={`py-1.5 ${c.right ? "text-right" : ""}`} aria-sort={c.key && c.key === sort ? (c.key === "name" ? "ascending" : "descending") : undefined}>
                        {c.key ? (
                          <Link href={customersHref({ q, filter, sort: c.key })} className="font-semibold" style={c.key === sort ? { color: "var(--color-ink)" } : undefined}>
                            {c.label}{c.key === sort ? (c.key === "name" ? " ↑" : " ↓") : ""}
                          </Link>
                        ) : (
                          c.label
                        )}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr key={r.id} className="border-t" style={{ borderColor: "var(--color-line)" }}>
                      <td className="py-1.5">
                        <Link href={`/customers/${r.id}`} className="font-semibold underline-offset-2 hover:underline">{r.name}</Link>
                      </td>
                      <td className="tabular-nums">{formatPhone(r.phone)}</td>
                      <td className="text-right tabular-nums">{r.visits}</td>
                      <td className="text-right tabular-nums">{m(r.spend)}</td>
                      <td style={isLapsed(r.lastVisitOn, today) ? { color: "var(--color-warn)" } : undefined}>{lastVisitText(r.lastVisitOn, today)}</td>
                      {showPoints && <td className="text-right tabular-nums">{r.points}</td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <div className="flex flex-wrap items-center justify-between gap-2 text-xs" style={{ color: "var(--color-ink-3)" }}>
              <span>{total} {total === 1 ? "guest" : "guests"} · page {Math.min(page, pages)} of {pages}</span>
              <span className="flex gap-2">
                {page > 1 ? <Link className="btn border" style={{ borderColor: "var(--color-line)", minHeight: 36, padding: "0 12px" }} href={customersHref({ q, filter, sort, page: page - 1 })}>Previous</Link> : null}
                {page < pages ? <Link className="btn border" style={{ borderColor: "var(--color-line)", minHeight: 36, padding: "0 12px" }} href={customersHref({ q, filter, sort, page: page + 1 })}>Next</Link> : null}
              </span>
            </div>
          </>
        )}
      </section>
    </div>
  );
}
