import Link from "next/link";
import { requireUser } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";
import { settingsSections } from "./sections";

/** Settings home: every section this person may open, under its module heading, with a line on what it holds. */
export default async function SettingsIndex() {
  const user = await requireUser();
  const supabase = await createClient();
  const { data: country } = await supabase.from("countries").select("tax_system_name").eq("code", user.country_code).maybeSingle();
  const all = settingsSections(user, country?.tax_system_name ?? "Tax");
  const groups: { group: string; items: typeof all }[] = [];
  for (const s of all) {
    const last = groups[groups.length - 1];
    if (last && last.group === s.group) last.items.push(s);
    else groups.push({ group: s.group, items: [s] });
  }

  return (
    <div>
      {groups.map((g) => (
        <section key={g.group} className="mb-6" aria-label={g.group}>
          <h2 className="mb-2 text-xs font-bold uppercase tracking-wider" style={{ color: "var(--color-ink-3)" }}>{g.group}</h2>
          <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            {g.items.map((s) => (
              <Link key={s.href} href={s.href} className="card block p-4">
                <div className="font-bold">{s.label}</div>
                <div className="mt-0.5 text-sm" style={{ color: "var(--color-ink-3)" }}>{s.hint}</div>
              </Link>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
