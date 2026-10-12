import type { ReactNode } from "react";

/**
 * A small Markdown reader for the Help pages. It understands what the guides use: ## and ### headings,
 * paragraphs, **bold**, *italic*, `code`, [links](url), numbered and bullet lists (one level of nesting),
 * tables and > quotes. Text is never treated as HTML.
 */

export type HelpSection = { id: string; title: string; body: string };

/** Splits the guide at its "## " headings. */
export function helpSections(md: string): HelpSection[] {
  const out: HelpSection[] = [];
  let cur: HelpSection | null = null;
  for (const line of md.split("\n")) {
    const h = line.match(/^## (.+)$/);
    if (h) {
      if (cur) out.push(cur);
      const title = h[1].trim();
      cur = { id: slug(title), title, body: "" };
    } else if (cur) cur.body += line + "\n";
  }
  if (cur) out.push(cur);
  return out;
}

function slug(s: string) {
  return (
    s
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "") || "section"
  );
}

/** Bold, italic, code and links inside one line. */
export function inline(text: string, keyBase = "i"): ReactNode[] {
  const out: ReactNode[] = [];
  const re = /(\*\*([^*]+)\*\*|\*([^*\s][^*]*?)\*|`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\))/g;
  let last = 0;
  let m: RegExpExecArray | null;
  let n = 0;
  while ((m = re.exec(text))) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const k = `${keyBase}-${n++}`;
    if (m[2] !== undefined) out.push(<strong key={k}>{inline(m[2], k)}</strong>);
    else if (m[3] !== undefined) out.push(<em key={k}>{inline(m[3], k)}</em>);
    else if (m[4] !== undefined)
      out.push(
        <code key={k} className="rounded px-1 text-[0.92em]" style={{ background: "var(--color-ground)" }}>
          {m[4]}
        </code>,
      );
    else if (m[5] !== undefined) {
      const href = m[6];
      const safe = /^(https?:\/\/|\/|#|mailto:)/.test(href) ? href : "#";
      out.push(
        <a key={k} href={safe} className="font-semibold underline" style={{ color: "var(--color-brand)" }} target={safe.startsWith("http") ? "_blank" : undefined} rel="noreferrer">
          {m[5]}
        </a>,
      );
    }
    last = m.index + m[0].length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

type ListItem = { text: string; children: { ordered: boolean; items: string[] } | null };

/** The body of a section as page elements. */
export function renderHelp(md: string): ReactNode[] {
  const lines = md.split("\n");
  const out: ReactNode[] = [];
  let i = 0;
  let key = 0;
  const k = () => `b${key++}`;

  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "") {
      i++;
      continue;
    }
    // ### heading
    const h3 = line.match(/^###\s+(.+)$/);
    if (h3) {
      out.push(
        <h3 key={k()} className="mt-5 text-base font-bold">
          {inline(h3[1])}
        </h3>,
      );
      i++;
      continue;
    }
    // table
    if (line.trimStart().startsWith("|") && lines[i + 1]?.match(/^\s*\|\s*:?-{2,}/)) {
      const row = (l: string) =>
        l
          .trim()
          .replace(/^\|/, "")
          .replace(/\|$/, "")
          .split("|")
          .map((c) => c.trim());
      const head = row(line);
      i += 2;
      const body: string[][] = [];
      while (i < lines.length && lines[i].trimStart().startsWith("|")) body.push(row(lines[i++]));
      const kk = k();
      out.push(
        <div key={kk} className="my-3 overflow-x-auto rounded-xl border" style={{ borderColor: "var(--color-line)" }}>
          <table className="w-full text-left text-sm">
            <thead style={{ background: "var(--color-ground)" }}>
              <tr>
                {head.map((c, j) => (
                  <th key={j} className="px-3 py-2 font-semibold">
                    {inline(c, `${kk}h${j}`)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {body.map((r, ri) => (
                <tr key={ri} className="border-t align-top" style={{ borderColor: "var(--color-line)" }}>
                  {r.map((c, j) => (
                    <td key={j} className="px-3 py-2">
                      {inline(c, `${kk}r${ri}c${j}`)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>,
      );
      continue;
    }
    // quote
    if (line.startsWith(">")) {
      const q: string[] = [];
      while (i < lines.length && lines[i].startsWith(">")) q.push(lines[i++].replace(/^>\s?/, ""));
      out.push(
        <blockquote key={k()} className="my-3 rounded-xl border-l-4 px-4 py-2 text-sm" style={{ borderColor: "var(--color-brand)", background: "var(--color-ground)" }}>
          {renderHelp(q.join("\n"))}
        </blockquote>,
      );
      continue;
    }
    // list
    const li = line.match(/^(\d+\.|-)\s+(.*)$/);
    if (li) {
      const ordered = li[1] !== "-";
      const items: ListItem[] = [];
      while (i < lines.length) {
        const m = lines[i].match(/^(\d+\.|-)\s+(.*)$/);
        const sub = lines[i].match(/^\s{2,}(\d+\.|-)\s+(.*)$/);
        if (m && (m[1] === "-") === !ordered) {
          items.push({ text: m[2], children: null });
          i++;
        } else if (sub && items.length) {
          const last = items[items.length - 1];
          if (!last.children) last.children = { ordered: sub[1] !== "-", items: [] };
          last.children.items.push(sub[2]);
          i++;
        } else break;
      }
      const kk = k();
      const Tag = ordered ? "ol" : "ul";
      out.push(
        <Tag key={kk} className={`my-2 space-y-1.5 pl-6 text-sm ${ordered ? "list-decimal" : "list-disc"}`}>
          {items.map((it, j) => (
            <li key={j}>
              {inline(it.text, `${kk}-${j}`)}
              {it.children &&
                (it.children.ordered ? (
                  <ol className="mt-1 list-decimal space-y-1 pl-5">
                    {it.children.items.map((s, x) => (
                      <li key={x}>{inline(s, `${kk}-${j}-${x}`)}</li>
                    ))}
                  </ol>
                ) : (
                  <ul className="mt-1 list-disc space-y-1 pl-5">
                    {it.children.items.map((s, x) => (
                      <li key={x}>{inline(s, `${kk}-${j}-${x}`)}</li>
                    ))}
                  </ul>
                ))}
            </li>
          ))}
        </Tag>,
      );
      continue;
    }
    // paragraph: consecutive plain lines
    const para: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() !== "" &&
      !lines[i].match(/^(###\s|>|\s*\||(\d+\.|-)\s)/)
    )
      para.push(lines[i++]);
    if (para.length === 0) {
      // A line no rule above took (should not happen): show it as text so nothing is lost.
      para.push(lines[i++]);
    }
    const kk = k();
    out.push(
      <p key={kk} className="my-2 text-sm leading-relaxed">
        {inline(para.join(" "), kk)}
      </p>,
    );
  }
  return out;
}
