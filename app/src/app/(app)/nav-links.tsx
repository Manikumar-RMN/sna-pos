"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

export function NavLinks({ links }: { links: { href: string; label: string }[] }) {
  const path = usePathname();
  return (
    <nav className="-mx-1 flex items-center gap-1 overflow-x-auto whitespace-nowrap text-sm">
      {links.map((l) => {
        // "/settings" should not light up while on its child "/settings/users" (Staff).
        const on =
          path === l.href ||
          (path.startsWith(l.href + "/") && !(l.href === "/settings" && path.startsWith("/settings/users")));
        return (
          <Link
            key={l.href}
            href={l.href}
            className="rounded-lg px-3 py-2 font-medium"
            style={on ? { background: "var(--color-brand-soft)", color: "var(--color-brand-strong)", fontWeight: 700 } : undefined}
          >
            {l.label}
          </Link>
        );
      })}
    </nav>
  );
}
