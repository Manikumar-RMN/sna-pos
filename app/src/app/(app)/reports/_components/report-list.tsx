import Link from "next/link";
import { groupReportLinks, type ReportAccess, type SectionKey } from "./report-links";

/** The reports of one section as clean rows under a dark heading per group (Operations, Sales, Items & staff ...). */
export function ReportList({ access, section, keep }: { access: ReportAccess; section: SectionKey; keep: string }) {
  const groups = groupReportLinks(access, section);
  return (
    <nav aria-label="Reports">
      {groups.map((g) => (
        <section key={g.group ?? "top"} className="rc-card">
          <h3>{g.group ?? "Sales summary"}</h3>
          {g.items.map((l) => {
            return (
              <Link key={l.href} href={`${l.href}${keep}`} className="rc-row">
                <span className="rc-t">{l.title}</span>
                <span className="rc-d">{l.blurb}</span>
                <span className="rc-go">Open →</span>
              </Link>
            );
          })}
        </section>
      ))}
    </nav>
  );
}
