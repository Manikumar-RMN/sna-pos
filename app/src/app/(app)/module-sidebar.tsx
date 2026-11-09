"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";

export type SideItem = { href: string; label: string };
export type SideGroup = { key: string; title: string; icon: string; items: SideItem[] };

const IC: Record<string, string> = {
  home: "M3 11l9-7 9 7M5 10v10h14V10M10 20v-6h4v6",
  pos: "M4 5h16v14H4zM8 10h8M8 14h5",
  inventory: "M4 7l8-4 8 4v10l-8 4-8-4zM4 7l8 4 8-4M12 11v10",
  reports: "M5 19V11M12 19V5M19 19v-6",
  setup: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM4 12h2M18 12h2M12 4v2M12 18v2",
  help: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.4-1 .9-1 1.7M12 17h.01",
};

function Ico({ k }: { k: string }) {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={IC[k] ?? IC.home} />
    </svg>
  );
}

/** The page that is open now: the longest item address that matches the path, so "/settings" does not light up on "/settings/menu". */
function activeHref(path: string, groups: SideGroup[]): string | null {
  let best: string | null = null;
  for (const g of groups) {
    for (const i of g.items) {
      const hit = path === i.href || path.startsWith(i.href + "/");
      if (hit && (best === null || i.href.length > best.length)) best = i.href;
    }
  }
  return best;
}

/**
 * Winsar-style side menu: one block per module, each listing that module's own screens.
 * The block holding the open page is open; the others fold away.
 * (every signed-in user except a counter tablet), and each block only lists screens this role may use.
 */
export function ModuleSidebar({ groups }: { groups: SideGroup[] }) {
  const path = usePathname();
  const on = activeHref(path, groups);
  const [closed, setClosed] = useState<Record<string, boolean>>({});
  const [openExtra, setOpenExtra] = useState<Record<string, boolean>>({});

  return (
    <nav aria-label="Modules" className="w-full text-sm">
      {groups.map((g) => {
        const holdsOpenPage = g.items.some((i) => i.href === on);
        const open = closed[g.key] === undefined ? holdsOpenPage || openExtra[g.key] === true : !closed[g.key];
        const single = g.items.length === 1;
        if (single) {
          const i = g.items[0];
          const here = i.href === on;
          return (
            <Link
              key={g.key}
              href={i.href}
              aria-current={here ? "page" : undefined}
              className="mb-0.5 flex min-h-11 items-center gap-2.5 rounded-xl px-3 font-bold"
              style={here ? { background: "rgba(255,255,255,0.18)", color: "#fff" } : { color: "rgba(255,255,255,0.85)" }}
            >
              <Ico k={g.icon} />
              {g.title}
            </Link>
          );
        }
        return (
          <div key={g.key} className="mb-0.5">
            <button
              type="button"
              aria-expanded={open}
              onClick={() => {
                setClosed({ ...closed, [g.key]: open });
                setOpenExtra({ ...openExtra, [g.key]: !open });
              }}
              className="flex min-h-11 w-full items-center gap-2.5 rounded-xl px-3 text-left font-bold"
              style={holdsOpenPage ? { color: "#fff" } : { color: "rgba(255,255,255,0.85)" }}
            >
              <Ico k={g.icon} />
              <span className="flex-1">{g.title}</span>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={{ transform: open ? "rotate(180deg)" : undefined, transition: "transform 120ms" }}>
                <path d="M6 9l6 6 6-6" />
              </svg>
            </button>
            {open && (
              <ul className="m-0 ml-4 list-none border-l p-0 pl-2" style={{ borderColor: "rgba(255,255,255,0.22)" }}>
                {g.items.map((i) => {
                  const here = i.href === on;
                  return (
                    <li key={i.href}>
                      <Link
                        href={i.href}
                        aria-current={here ? "page" : undefined}
                        className="flex min-h-10 items-center rounded-lg px-3 font-semibold"
                        style={here ? { background: "rgba(255,255,255,0.18)", color: "#fff" } : { color: "rgba(255,255,255,0.78)" }}
                      >
                        {i.label}
                      </Link>
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        );
      })}
    </nav>
  );
}
