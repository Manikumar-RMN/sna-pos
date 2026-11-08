"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";

export type SettingsLink = { href: string; label: string; hint: string; group: string };

/** Links in order, folded into their module groups (the list is already sorted by group). */
function grouped(links: SettingsLink[]): { group: string; items: SettingsLink[] }[] {
  const out: { group: string; items: SettingsLink[] }[] = [];
  for (const l of links) {
    const last = out[out.length - 1];
    if (last && last.group === l.group) last.items.push(l);
    else out.push({ group: l.group, items: [l] });
  }
  return out;
}

/**
 * Settings menu. Tablet and desktop: a side list, every item under its module heading.
 * Phone: one dropdown with the same headings, so the page content gets the whole screen.
 */
export function SettingsNav({ links }: { links: SettingsLink[] }) {
  const path = usePathname();
  const router = useRouter();
  const groups = grouped(links);
  const current = links.find((l) => path === l.href || path.startsWith(l.href + "/"))?.href ?? "";

  return (
    <>
      <div className="md:hidden">
        <label className="sr-only" htmlFor="settings-jump">Settings section</label>
        <select
          id="settings-jump"
          className="field h-12 w-full text-base font-semibold"
          value={current}
          onChange={(e) => router.push(e.target.value)}
        >
          {groups.map((g) => (
            <optgroup key={g.group} label={g.group}>
              {g.items.map((l) => (
                <option key={l.href} value={l.href}>{l.label}</option>
              ))}
            </optgroup>
          ))}
        </select>
      </div>

      <nav aria-label="Settings" className="card hidden overflow-hidden md:block">
        {groups.map((g, gi) => (
          <div key={g.group} style={gi > 0 ? { borderTop: "1px solid var(--color-line)" } : undefined}>
            <div
              className="px-4 pb-1 pt-3 text-[11px] font-bold uppercase tracking-wider"
              style={{ color: "var(--color-ink-3)" }}
            >
              {g.group}
            </div>
            <ul className="px-2 pb-2">
              {g.items.map((l) => {
                const on = path === l.href || path.startsWith(l.href + "/");
                return (
                  <li key={l.href}>
                    <Link
                      href={l.href}
                      aria-current={on ? "page" : undefined}
                      className="block rounded-xl px-3 py-2"
                      style={on ? { background: "var(--color-brand)", color: "#fff" } : { color: "var(--color-ink)" }}
                    >
                      <span className="block text-[14px] font-bold leading-tight">{l.label}</span>
                      <span className="mt-0.5 block text-xs leading-snug" style={{ color: on ? "rgba(255,255,255,0.8)" : "var(--color-ink-3)" }}>
                        {l.hint}
                      </span>
                    </Link>
                  </li>
                );
              })}
            </ul>
          </div>
        ))}
      </nav>
    </>
  );
}
