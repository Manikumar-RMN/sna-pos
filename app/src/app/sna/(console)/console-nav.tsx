"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

/** The console's top menu. The page you are on is highlighted. */
export function ConsoleNav({ links }: { links: { href: string; label: string }[] }) {
  const path = usePathname() ?? "";
  // "Clients" also covers a single client's page (/sna/r/...).
  const on = (href: string) => (href === "/sna" ? path === "/sna" || path.startsWith("/sna/r/") : path === href || path.startsWith(`${href}/`));
  return (
    <nav aria-label="Console" className="flex flex-wrap gap-1 text-sm">
      {links.map((l) => {
        const active = on(l.href);
        return (
          <Link
            key={l.href}
            href={l.href}
            aria-current={active ? "page" : undefined}
            className="rounded-xl px-3 py-2 font-semibold"
            style={active ? { background: "rgba(255,255,255,0.16)", color: "#fff" } : { color: "rgba(255,255,255,0.8)" }}
          >
            {l.label}
          </Link>
        );
      })}
    </nav>
  );
}
