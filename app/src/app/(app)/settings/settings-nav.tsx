"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export type SettingsLink = { href: string; label: string; hint: string; group: string };

/** Settings sub-menu: a column on tablet/desktop, a scrolling row on phones. */
export function SettingsNav({ links }: { links: SettingsLink[] }) {
  const path = usePathname();
  return (
    <nav aria-label="Settings" className="card flex gap-1 overflow-x-auto p-2 md:flex-col md:overflow-visible">
      {links.map((l, i) => {
        const on = path === l.href || path.startsWith(l.href + "/");
        const heading = l.group !== links[i - 1]?.group ? l.group : null;
        return (
          <div key={l.href} className="contents">
          {heading && (
            <div className="hidden px-3.5 pb-0.5 pt-2.5 text-[10px] font-bold uppercase tracking-wide md:block" style={{ color: "var(--color-ink-3)" }}>
              {heading}
            </div>
          )}
          <Link
            href={l.href}
            aria-current={on ? "page" : undefined}
            className="flex shrink-0 flex-col justify-center rounded-2xl px-3.5 py-2.5 md:min-h-[56px]"
            style={on ? { background: "var(--color-brand)", color: "#fff" } : { color: "var(--color-ink)" }}
          >
            <span className="text-[15px] font-bold">{l.label}</span>
            <span className="hidden text-xs md:block" style={{ color: on ? "rgba(255,255,255,0.78)" : "var(--color-ink-3)" }}>
              {l.hint}
            </span>
          </Link>
          </div>
        );
      })}
    </nav>
  );
}
