"use client";

import { useMemo, useState } from "react";
import { helpSections, renderHelp } from "@/lib/help/markdown";

/**
 * The Help page: contents on the left (on top on a phone), a search box, and the guide.
 * Searching shows only the sections whose text has every word typed.
 */
export function HelpView({ guide, title, intro }: { guide: string; title: string; intro: string }) {
  const sections = useMemo(() => helpSections(guide), [guide]);
  const [q, setQ] = useState("");
  const words = q.toLowerCase().split(/\s+/).filter(Boolean);
  const shown = words.length
    ? sections.filter((s) => {
        const t = `${s.title}\n${s.body}`.toLowerCase();
        return words.every((w) => t.includes(w));
      })
    : sections;

  return (
    <div className="mx-auto max-w-6xl">
      <div className="mb-4">
        <h1 className="font-display text-2xl font-bold">{title}</h1>
        <p className="mt-1 text-sm" style={{ color: "var(--color-ink-3)" }}>
          {intro}
        </p>
      </div>
      <div className="grid gap-5 md:grid-cols-[230px_1fr]">
        <aside className="md:sticky md:top-4 md:self-start">
          <label className="block">
            <span className="sr-only">Search the guide</span>
            <input className="field" type="search" placeholder="Search, e.g. KOT, prefix, refund" value={q} onChange={(e) => setQ(e.target.value)} />
          </label>
          <nav aria-label="Contents" className="mt-3 hidden space-y-0.5 text-sm md:block">
            {sections.map((s) => (
              <a key={s.id} href={`#${s.id}`} className="block rounded-lg px-2 py-1.5 hover:underline" style={{ color: "var(--color-ink-2)" }} onClick={() => setQ("")}>
                {s.title}
              </a>
            ))}
          </nav>
          <details className="mt-3 md:hidden">
            <summary className="cursor-pointer text-sm font-semibold">Contents</summary>
            <nav aria-label="Contents" className="mt-2 space-y-0.5 text-sm">
              {sections.map((s) => (
                <a key={s.id} href={`#${s.id}`} className="block px-2 py-1" style={{ color: "var(--color-ink-2)" }} onClick={() => setQ("")}>
                  {s.title}
                </a>
              ))}
            </nav>
          </details>
        </aside>
        <div className="min-w-0 space-y-4">
          {words.length > 0 && (
            <p className="text-sm" role="status" style={{ color: "var(--color-ink-3)" }}>
              {shown.length === 0 ? "Nothing in the guide matches. Try another word." : `${shown.length} ${shown.length === 1 ? "section matches" : "sections match"}.`}
            </p>
          )}
          {shown.map((s) => (
            <section key={s.id} id={s.id} className="card scroll-mt-4 p-5">
              <h2 className="text-lg font-bold">{s.title}</h2>
              {renderHelp(s.body)}
            </section>
          ))}
        </div>
      </div>
    </div>
  );
}
