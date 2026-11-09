"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useId, useRef, useState, type RefObject } from "react";
import { Dual } from "./lang";

/** One menu entry. `children` makes it a drop-down group (Reports); the entry itself still links to `href`. */
export type NavItem = { href: string; label: string; children?: { href: string; label: string; group?: string; also?: string[] }[] };

/** The child page that is open now. The group's own page only counts on an exact match. */
function childOn(path: string, group: string, href: string) {
  return href === group ? path === href : isOn(path, href);
}

/** Line icons for the side menu (24×24, drawn with a single path each). */
const ICONS: Record<string, string> = {
  "/dashboard": "M3 11l9-7 9 7M5 10v10h14V10M10 20v-6h4v6",
  "/pos": "M4 5h16v14H4zM8 10h8M8 14h5",
  "/stock": "M4 7l8-4 8 4v10l-8 4-8-4zM4 7l8 4 8-4M12 11v10",
  "/customers": "M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20c0-3.6 2.9-6.5 6.5-6.5s6.5 2.9 6.5 6.5M16.5 5a3.2 3.2 0 0 1 0 6M18 14c2.2.7 3.5 2.6 3.5 5",
  "/purchases": "M3 9h18l-2 11H5zM8 9l4-6 4 6M9.5 13v3.5M14.5 13v3.5",
  "/owner": "M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2",
  "/reservations": "M5 5h14v15H5zM5 9h14M9 3v4M15 3v4",
  "/loyalty": "M12 21s-7-4.5-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 11c0 5.5-7 10-7 10z",
  "/timesheets": "M12 7v5l3 2M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z",
  "/table-orders": "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h2v2h-2zM18 18h2v2h-2zM14 18h2M18 14h2",
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
export function NavRail({ links }: { links: NavItem[] }) {
  const path = usePathname();
  return (
    <nav aria-label="Main" className="flex flex-col items-center gap-1.5">
      {links.map((l) => {
        const on = isOn(path, l.href);
        if (l.children?.length) return <RailGroup key={l.href} item={l} on={on} path={path} />;
        return (
          <Link
            key={l.href}
            href={l.href}
            aria-current={on ? "page" : undefined}
            className="flex w-[60px] min-h-[56px] flex-col items-center justify-center gap-[3px] rounded-2xl text-[10px] font-bold"
            style={on ? { background: "rgba(255,255,255,0.16)", color: "#fff" } : { color: "rgba(255,255,255,0.74)" }}
          >
            <Icon href={l.href} />
            <Dual text={l.label} />
          </Link>
        );
      })}
    </nav>
  );
}

/** Horizontal menu for phones. */
export function NavLinks({ links }: { links: NavItem[] }) {
  const path = usePathname();
  return (
    <nav aria-label="Main" className="-mx-1 flex items-center gap-1 overflow-x-auto whitespace-nowrap text-sm">
      {links.map((l) => {
        const on = isOn(path, l.href);
        if (l.children?.length) return <BarGroup key={l.href} item={l} on={on} path={path} />;
        return (
          <Link
            key={l.href}
            href={l.href}
            aria-current={on ? "page" : undefined}
            className="flex items-center gap-1.5 rounded-xl px-3 py-2 font-semibold"
            style={on ? { background: "rgba(255,255,255,0.16)", color: "#fff" } : { color: "rgba(255,255,255,0.8)" }}
          >
            <Icon href={l.href} />
            <Dual text={l.label} />
          </Link>
        );
      })}
    </nav>
  );
}

function Chevron({ open }: { open: boolean }) {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={{ transform: open ? "rotate(180deg)" : undefined, transition: "transform 120ms" }}>
      <path d="M6 9l6 6 6-6" />
    </svg>
  );
}

/**
 * Open/close state for a drop-down. It closes on Escape (focus goes back to the
 * button), on a press outside the button or list, on a page change and when the
 * page scrolls or resizes (the list is fixed, so it would drift from its button).
 */
function useDropdown(path: string) {
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState<{ left: number; top: number }>({ left: 0, top: 0 });
  const btn = useRef<HTMLButtonElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const [lastPath, setLastPath] = useState(path);
  if (lastPath !== path) {
    setLastPath(path);
    setOpen(false);
  }
  useEffect(() => {
    if (!open) return;
    const down = (e: Event) => {
      const t = e.target as Node | null;
      if (t && (btn.current?.contains(t) || box.current?.contains(t))) return;
      setOpen(false);
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setOpen(false);
        btn.current?.focus();
      }
    };
    const close = (e: Event) => {
      if (e.target instanceof Node && box.current?.contains(e.target)) return;
      setOpen(false);
    };
    document.addEventListener("pointerdown", down);
    document.addEventListener("keydown", key);
    window.addEventListener("resize", close);
    window.addEventListener("scroll", close, true);
    return () => {
      document.removeEventListener("pointerdown", down);
      document.removeEventListener("keydown", key);
      window.removeEventListener("resize", close);
      window.removeEventListener("scroll", close, true);
    };
  }, [open]);
  /** `side`: beside the button (rail) or under it (phone bar). */
  function toggle(anchor: HTMLElement | null, side: "right" | "below") {
    if (!open && anchor) {
      const r = anchor.getBoundingClientRect();
      setPos(side === "right" ? { left: r.right + 10, top: Math.max(8, r.top) } : { left: Math.max(8, Math.min(r.left, window.innerWidth - 248)), top: r.bottom + 6 });
    }
    setOpen(!open);
  }
  return { open, setOpen, pos, btn, box, toggle };
}

function DropList({ id, item, path, pos, box, onPick }: { id: string; item: NavItem; path: string; pos: { left: number; top: number }; box: RefObject<HTMLDivElement | null>; onPick: () => void }) {
  return (
    <div
      ref={box}
      id={id}
      className="fixed z-50 w-60 max-w-[calc(100vw-16px)] overflow-y-auto rounded-2xl border p-1.5 shadow-lg"
      style={{ left: pos.left, top: pos.top, maxHeight: "calc(100vh - 24px)", background: "var(--color-surface)", borderColor: "var(--color-line)", color: "var(--color-ink)" }}
    >
      <ul className="m-0 list-none p-0">
        {item.children?.map((c, i) => {
          const here = childOn(path, item.href, c.href) || (c.also ?? []).some((h) => isOn(path, h));
          const heading = c.group && c.group !== item.children?.[i - 1]?.group ? c.group : null;
          return (
            <li key={c.href}>
              {heading && (
                <div className="px-3 pb-1 pt-2 text-[10px] font-bold uppercase tracking-wide" style={{ color: "var(--color-ink-3)" }}>
                  {heading}
                </div>
              )}
              <Link
                href={c.href}
                onClick={onPick}
                aria-current={here ? "page" : undefined}
                className="flex min-h-11 items-center rounded-xl px-3 text-sm font-semibold"
                style={here ? { background: "var(--color-brand-soft)", color: "var(--color-brand)" } : undefined}
              >
                <Dual text={c.label} />
              </Link>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

/** Rail: the Reports icon opens its page; the chevron under it opens a list of reports beside the rail. */
function RailGroup({ item, on, path }: { item: NavItem; on: boolean; path: string }) {
  const id = useId();
  const d = useDropdown(path);
  return (
    <div className="flex flex-col items-center">
      <Link
        href={item.href}
        aria-current={path === item.href ? "page" : undefined}
        className="flex w-[60px] min-h-[56px] flex-col items-center justify-center gap-[3px] rounded-t-2xl text-[10px] font-bold"
        style={on ? { background: "rgba(255,255,255,0.16)", color: "#fff" } : { color: "rgba(255,255,255,0.74)" }}
      >
        <Icon href={item.href} />
        <Dual text={item.label} />
      </Link>
      <button
        ref={d.btn}
        type="button"
        aria-expanded={d.open}
        aria-controls={id}
        aria-label={`${item.label} list`}
        onClick={() => d.toggle(d.btn.current, "right")}
        className="flex min-h-11 w-[60px] items-center justify-center rounded-b-2xl"
        style={on || d.open ? { background: "rgba(255,255,255,0.16)", color: "#fff" } : { color: "rgba(255,255,255,0.74)" }}
      >
        <Chevron open={d.open} />
      </button>
      {d.open && <DropList id={id} item={item} path={path} pos={d.pos} box={d.box} onPick={() => d.setOpen(false)} />}
    </div>
  );
}

/** Phone bar: the Reports link plus a chevron that drops the list below it. */
function BarGroup({ item, on, path }: { item: NavItem; on: boolean; path: string }) {
  const id = useId();
  const d = useDropdown(path);
  const style = on || d.open ? { background: "rgba(255,255,255,0.16)", color: "#fff" } : { color: "rgba(255,255,255,0.8)" };
  return (
    <div className="flex items-center rounded-xl" style={style}>
      <Link href={item.href} aria-current={path === item.href ? "page" : undefined} className="flex items-center gap-1.5 py-2 pl-3 pr-1 font-semibold">
        <Icon href={item.href} />
        <Dual text={item.label} />
      </Link>
      <button
        ref={d.btn}
        type="button"
        aria-expanded={d.open}
        aria-controls={id}
        aria-label={`${item.label} list`}
        onClick={() => d.toggle(d.btn.current?.parentElement ?? null, "below")}
        className="flex min-h-11 min-w-9 items-center justify-center rounded-xl pr-1"
      >
        <Chevron open={d.open} />
      </button>
      {d.open && <DropList id={id} item={item} path={path} pos={d.pos} box={d.box} onPick={() => d.setOpen(false)} />}
    </div>
  );
}
