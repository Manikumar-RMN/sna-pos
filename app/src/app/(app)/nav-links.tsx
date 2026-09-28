"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

/** Line icons for the side menu (24×24, drawn with a single path each). */
const ICONS: Record<string, string> = {
  "/dashboard": "M3 11l9-7 9 7M5 10v10h14V10M10 20v-6h4v6",
  "/pos": "M4 5h16v14H4zM8 10h8M8 14h5",
  "/bills": "M6 3h12v18l-3-2-3 2-3-2-3 2zM9 8h6M9 12h6",
  "/kitchen": "M8 3c0 2 1.5 2.5 1.5 4.5S8 10 8 10M12 3c0 2 1.5 2.5 1.5 4.5S12 10 12 10M4 13h16l-1.5 7h-13z",
  "/shift": "M12 7v5l3 2M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z",
  "/reports": "M5 19V11M12 19V5M19 19v-6",
  "/menu": "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM8.5 9.5h.01M15.5 9.5h.01M12 15.5h.01",
  "/settings/users":
    "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM3 20c0-3.3 2.7-6 6-6s6 2.7 6 6M16 4.5a3.5 3.5 0 0 1 0 6.5M21 20c0-2.6-1.6-4.8-4-5.6",
  "/settings": "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM4 12h2M18 12h2M12 4v2M12 18v2",
};

function isOn(path: string, href: string) {
  return path === href || path.startsWith(href + "/");
}

function Icon({ href }: { href: string }) {
  return (
    <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={ICONS[href] ?? ICONS["/dashboard"]} />
    </svg>
  );
}

/** Vertical icon menu on the green rail (tablet and desktop). */
export function NavRail({ links }: { links: { href: string; label: string }[] }) {
  const path = usePathname();
  return (
    <nav aria-label="Main" className="flex flex-col items-center gap-1.5">
      {links.map((l) => {
        const on = isOn(path, l.href);
        return (
          <Link
            key={l.href}
            href={l.href}
            aria-current={on ? "page" : undefined}
            className="flex w-[60px] min-h-[56px] flex-col items-center justify-center gap-[3px] rounded-2xl text-[10px] font-bold"
            style={on ? { background: "rgba(255,255,255,0.16)", color: "#fff" } : { color: "rgba(255,255,255,0.74)" }}
          >
            <Icon href={l.href} />
            {l.label}
          </Link>
        );
      })}
    </nav>
  );
}

/** Horizontal menu for phones. */
export function NavLinks({ links }: { links: { href: string; label: string }[] }) {
  const path = usePathname();
  return (
    <nav aria-label="Main" className="-mx-1 flex items-center gap-1 overflow-x-auto whitespace-nowrap text-sm">
      {links.map((l) => {
        const on = isOn(path, l.href);
        return (
          <Link
            key={l.href}
            href={l.href}
            aria-current={on ? "page" : undefined}
            className="flex items-center gap-1.5 rounded-xl px-3 py-2 font-semibold"
            style={on ? { background: "rgba(255,255,255,0.16)", color: "#fff" } : { color: "rgba(255,255,255,0.8)" }}
          >
            <Icon href={l.href} />
            {l.label}
          </Link>
        );
      })}
    </nav>
  );
}
