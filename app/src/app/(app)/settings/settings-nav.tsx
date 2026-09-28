"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export type SettingsLink = { href: string; label: string; hint: string };

/** Settings sub-menu: a column on tablet/desktop, a scrolling row on phones. */
export function SettingsNav({ links }: { links: SettingsLink[] }) {
  const path = usePathname();
  return (
    <nav aria-label="Settings" className="card flex gap-1 overflow-x-auto p-2 md:flex-col md:overflow-visible">
      {links.map((l) => {
        const on = path === l.href || path.startsWith(l.href + "/");
        return (
          <Link
            key={l.href}
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
        );
      })}
    </nav>
  );
}
